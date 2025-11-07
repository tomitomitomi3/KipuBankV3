# KipuBankV3

## Descripción General

**KipuBankV3** es una versión mejorada del contrato `KipuBankV2`
El contrato permite a los usuarios depositar ETH, USDC o cualquier token ERC20 que posea un par directo con USDC en Uniswap V2.  
Todos los depósitos se convierten automáticamente a USDC y se acreditan en el balance interno del usuario, respetando un límite máximo total (`bankCap`).

## Funcionalidades Principales

### 1. Depósitos Generalizados
El contrato soporta tres tipos de depósito:
- **ETH**: se intercambia automáticamente a USDC mediante Uniswap V2.
- **USDC**: se acredita directamente al saldo del usuario sin swap.
- **Otros tokens ERC20**: siempre que tengan un par directo con USDC, son intercambiados automáticamente a USDC mediante Uniswap V2.

### 2. Swaps Automáticos en Uniswap V2
Todos los depósitos en tokens distintos de USDC se convierten internamente a USDC usando:
- `swapExactETHForTokensSupportingFeeOnTransferTokens` para ETH.
- `swapExactTokensForTokensSupportingFeeOnTransferTokens` para tokens ERC20.

El contrato consulta `getAmountsOut` para estimar la conversión esperada y aplicar un margen de slippage definido en basis points (`slippageBps`).

### 3. Control del Tope del Banco (Bank Cap)
Antes de aceptar un depósito, el contrato valida que el nuevo total en USDC no supere el límite (`topeBancoUSD6`).

Si el depósito excede este límite:
- La transacción se revierte.
- En el caso de depósitos ERC20, el monto se devuelve al usuario.

## Despliegue

### Requisitos Previos
- Remix IDE o Hardhat.
- Red de prueba **Sepolia**.
- Fondos en ETH (Sepolia faucet).
- Direcciones válidas de:
  - Router Uniswap V2.
  - Token USDC (o Mock USDC de prueba).

### Constructor
```solidity
constructor(address _router, address _usdc, uint256 _topeBancoUSD6)
