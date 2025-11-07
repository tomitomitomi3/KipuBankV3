// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
KipuBankV3
- Deposita ETH, USDC o cualquier ERC20 con par directo USDC en Uniswap V2
- Los depositos distintos a USDC se intercambian a USDC usando Uniswap V2 Router
- Saldos internos se mantienen en USDC units (6 decimales)
- Se respeta `bankCap` en USDC (6 decimales)
- Roles: AccessControl (ADMIN, PAUSER)
- Seguridad: SafeERC20, ReentrancyGuard, checks-effects-interactions
*/

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IUniswapV2Router02 {
    function WETH() external pure returns (address);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external payable;

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path,
        address to,
        uint deadline
    ) external;

    function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts);
}

contract KipuBankV3 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ROL_ADMIN = DEFAULT_ADMIN_ROLE;
    bytes32 public constant ROL_PAUSADOR = keccak256("ROL_PAUSADOR");

    error DepositoCero();
    error TopeBancoUSDExcedido(uint256 intentoUSD, uint256 topeUSD);
    error SaldoInsuficiente(uint256 saldo, uint256 solicitado);
    error TransferenciaFallida();
    error NoEsAdmin();
    error TokenSinPairConUSDC(address token);
    error SwapFallido();
    error USDCNotSet();
    error SlippageProtegido(uint256 esperado, uint256 minimoAceptado);

    event DepositoUSDCEquivalente(address indexed usuario, address indexed origenToken, uint256 montoOrigen, uint256 montoUSDC);
    event RetiroUSDC(address indexed usuario, uint256 montoUSDC);
    event TopeBancoActualizado(uint256 nuevoTopeUSD);
    event RouterActualizado(address nuevoRouter);
    event USDCSeteado(address usdc);

    address public immutable creador;
    IUniswapV2Router02 public uniswapRouter;
    address public usdc; // direccion del USDC token 
    uint8 public constant DECIMALES_USD = 6;

    mapping(address => uint256) public saldosUSDC;
    uint256 public totalUSDCDeposado; 

    uint256 public topeBancoUSD6;

    mapping(address => uint8) private cacheDecimalesToken;

    modifier soloAdmin() {
        if (!hasRole(ROL_ADMIN, msg.sender)) revert NoEsAdmin();
        _;
    }

    constructor(address _router, address _usdc, uint256 _topeBancoUSD6) {
        require(_router != address(0), "Router invalido");
        require(_usdc != address(0), "USDC invalido");
        creador = msg.sender;
        uniswapRouter = IUniswapV2Router02(_router);
        usdc = _usdc;
        topeBancoUSD6 = _topeBancoUSD6;

        _grantRole(ROL_ADMIN, msg.sender);
        _grantRole(ROL_PAUSADOR, msg.sender);
    }

    /// @notice Depositar ETH y acreditar saldo en USDC.
    function depositarETH(uint16 slippageBps) external payable nonReentrant {
        if (msg.value == 0) revert DepositoCero();
        if (usdc == address(0)) revert USDCNotSet();
        
        address[] memory path = new address[](2);
        address weth = uniswapRouter.WETH();
        path[0] = weth;
        path[1] = usdc;

        uint[] memory amountsOut = uniswapRouter.getAmountsOut(msg.value, path);
        uint expectedUSDC = amountsOut[amountsOut.length - 1];

        uint minOut = _applySlippage(expectedUSDC, slippageBps);

        uint256 nuevoTotal = totalUSDCDeposado + expectedUSDC;
        if (topeBancoUSD6 > 0 && nuevoTotal > topeBancoUSD6) {
            revert TopeBancoUSDExcedido(nuevoTotal, topeBancoUSD6);
        }

        uint deadline = block.timestamp + 300; 
        uint usdcBefore = IERC20(usdc).balanceOf(address(this));
        uniswapRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: msg.value}(
            uint(minOut),
            path,
            address(this),
            deadline
        );
        uint usdcAfter = IERC20(usdc).balanceOf(address(this));
        uint received = usdcAfter - usdcBefore;

        saldosUSDC[msg.sender] += received;
        totalUSDCDeposado += received;

        emit DepositoUSDCEquivalente(msg.sender, address(0), msg.value, received);
    }

    /// @notice Depositar un ERC20: si es USDC se almacena directo; si no -> swap token -> USDC
    /// @param token Token a depositar (no address(0))
    /// @param monto cantidad en la unidad del token
    /// @param slippageBps tolerancia de slippage en bps
    function depositarERC20(address token, uint256 monto, uint16 slippageBps) external nonReentrant {
        if (monto == 0) revert DepositoCero();
        require(token != address(0), "usar depositarETH para ETH");
        if (usdc == address(0)) revert USDCNotSet();

        IERC20(token).safeTransferFrom(msg.sender, address(this), monto);

        if (token == usdc) {
            uint256 nuevoTotal = totalUSDCDeposado + monto;
            if (topeBancoUSD6 > 0 && nuevoTotal > topeBancoUSD6) {
                IERC20(usdc).safeTransfer(msg.sender, monto);
                revert TopeBancoUSDExcedido(nuevoTotal, topeBancoUSD6);
            }
            saldosUSDC[msg.sender] += monto;
            totalUSDCDeposado += monto;
            emit DepositoUSDCEquivalente(msg.sender, token, monto, monto);
            return;
        }

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = usdc;

        uint expectedUSDC;
        try uniswapRouter.getAmountsOut(monto, path) returns (uint[] memory amounts) {
            expectedUSDC = amounts[amounts.length - 1];
            if (expectedUSDC == 0) revert TokenSinPairConUSDC(token);
        } catch {
            IERC20(token).safeTransfer(msg.sender, monto);
            revert TokenSinPairConUSDC(token);
        }

        uint256 nuevoTotal = totalUSDCDeposado + expectedUSDC;
        if (topeBancoUSD6 > 0 && nuevoTotal > topeBancoUSD6) {
            IERC20(token).safeTransfer(msg.sender, monto);
            revert TopeBancoUSDExcedido(nuevoTotal, topeBancoUSD6);
        }

        _approveMaxIfNeeded(IERC20(token), address(uniswapRouter), monto);

        uint minOut = _applySlippage(expectedUSDC, slippageBps);
        uint deadline = block.timestamp + 300;

        uint usdcBefore = IERC20(usdc).balanceOf(address(this));
        uniswapRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            monto,
            uint(minOut),
            path,
            address(this),
            deadline
        );
        uint usdcAfter = IERC20(usdc).balanceOf(address(this));
        uint received = usdcAfter - usdcBefore;

        saldosUSDC[msg.sender] += received;
        totalUSDCDeposado += received;

        emit DepositoUSDCEquivalente(msg.sender, token, monto, received);
    }

    /// @notice Retirar USDC del banco 
    function retirarUSDC(uint256 monto) external nonReentrant {
        uint256 saldo = saldosUSDC[msg.sender];
        if (monto == 0 || monto > saldo) revert SaldoInsuficiente(saldo, monto);

        saldosUSDC[msg.sender] = saldo - monto;
        totalUSDCDeposado -= monto;

        IERC20(usdc).safeTransfer(msg.sender, monto);
        emit RetiroUSDC(msg.sender, monto);
    }

    /// @notice Ver saldo USDC interno de un usuario
    function verSaldoUSDC(address usuario) external view returns (uint256) {
        return saldosUSDC[usuario];
    }

    /// @notice Actualizar bank cap 
    function actualizarTopeBancoUSD(uint256 nuevoTopeUSD6) external soloAdmin {
        topeBancoUSD6 = nuevoTopeUSD6;
        emit TopeBancoActualizado(nuevoTopeUSD6);
    }

    /// @notice Actualizar router Uniswap
    function actualizarRouter(address nuevoRouter) external soloAdmin {
        require(nuevoRouter != address(0), "Router 0");
        uniswapRouter = IUniswapV2Router02(nuevoRouter);
        emit RouterActualizado(nuevoRouter);
    }

    /// @notice Setear USDC si fuese necesario
    function setUSDC(address _usdc) external soloAdmin {
        require(_usdc != address(0), "USDC 0");
        usdc = _usdc;
        emit USDCSeteado(_usdc);
    }

    /// @notice Rescue general (solo admin)
    function rescatarERC20(address token, address destinatario, uint256 monto) external soloAdmin {
        require(destinatario != address(0), "dest 0");
        IERC20(token).safeTransfer(destinatario, monto);
    }

    /// @notice Rescue ETH
    function rescatarETH(address payable destinatario, uint256 monto) external soloAdmin {
        (bool ok, ) = destinatario.call{value: monto}("");
        require(ok, "Fallo envio ETH");
    }

    receive() external payable {
        this.depositarETH(200);
    }

    fallback() external payable {
        this.depositarETH(200);
    }

    /// @dev calcula minOut aplicando bps slippage 
    function _applySlippage(uint amount, uint16 slippageBps) internal pure returns (uint) {
        if (slippageBps > 10000) slippageBps = 10000; 
        return (amount * (10000 - slippageBps)) / 10000;
    }

    /// @dev aprueba max si allowance insuficiente
    function _approveMaxIfNeeded(IERC20 token, address spender, uint256 amount) internal {
            uint256 allowance = token.allowance(address(this), spender);
            if (allowance < amount) {
                if (allowance > 0) {
                    token.approve(spender, 0); 
                }
                token.approve(spender, type(uint256).max);
            }
    }
}
