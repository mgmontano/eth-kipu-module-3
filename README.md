# SimpleSwap

A decentralized exchange (DEX) smart contract that replicates basic Uniswap functionality using the Automated Market Maker (AMM) model with constant product formula.

## 🚀 Features

- **Liquidity Provision**: Add and remove liquidity to earn trading fees
- **Token Swapping**: Swap tokens using the constant product formula (x * y = k)
- **Trading Fees**: 0.3% fee on all trades, distributed to liquidity providers
- **Slippage Protection**: Built-in minimum amount requirements
- **Deadline Protection**: Transaction expiration timestamps
- **Security**: Reentrancy protection and comprehensive input validation

## 📋 Contract Overview

SimpleSwap is an ERC20-compliant liquidity pool contract that enables:
- Creating liquidity pools for any ERC20 token pair
- Adding/removing liquidity proportionally
- Swapping tokens with automatic price discovery
- Earning fees as a liquidity provider

## 🛠 Technical Specifications

- **Solidity Version**: ^0.8.19
- **License**: MIT
- **Dependencies**: OpenZeppelin Contracts
- **Trading Fee**: 0.3% (997/1000 factor)
- **Minimum Liquidity**: 1,000 tokens (burned on first deposit)

## 🏗 Architecture

### Core Components

1. **Liquidity Management**
   - `addLiquidity()`: Deposit tokens to provide liquidity
   - `removeLiquidity()`: Withdraw tokens and earned fees

2. **Token Swapping**
   - `swapExactTokensForTokens()`: Swap exact input for variable output

3. **Price Discovery**
   - `getPrice()`: Get current token price ratio
   - `getAmountOut()`: Calculate swap output amounts

### State Variables

- `reserveA` / `reserveB`: Internal token reserves
- `totalLiquidity`: Total LP tokens in circulation
- `liquidityBalance`: Individual LP token balances
- `tokenA` / `tokenB`: Paired token addresses

## 🔧 Usage

### Prerequisites

1. Deploy the contract with two ERC20 token addresses
2. Approve token transfers to the contract address
3. Ensure sufficient token balances for operations

### Adding Liquidity

```solidity
function addLiquidity(
    address tokenA,
    address tokenB,
    uint256 amountADesired,
    uint256 amountBDesired,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
) external returns (uint256 amountA, uint256 amountB, uint256 liquidity)
```

**Parameters:**
- `tokenA/tokenB`: Token addresses in the pair
- `amountADesired/amountBDesired`: Desired amounts to deposit
- `amountAMin/amountBMin`: Minimum amounts (slippage protection)
- `to`: Address to receive LP tokens
- `deadline`: Transaction deadline timestamp

### Removing Liquidity

```solidity
function removeLiquidity(
    address tokenA,
    address tokenB,
    uint256 liquidity,
    uint256 amountAMin,
    uint256 amountBMin,
    address to,
    uint256 deadline
) external returns (uint256 amountA, uint256 amountB)
```

### Swapping Tokens

```solidity
function swapExactTokensForTokens(
    uint256 amountIn,
    uint256 amountOutMin,
    address[] calldata path,
    address to,
    uint256 deadline
) external returns (uint256[] memory amounts)
```

**Parameters:**
- `amountIn`: Exact amount of input tokens
- `amountOutMin`: Minimum output amount (slippage protection)
- `path`: Array of [tokenIn, tokenOut] addresses
- `to`: Address to receive output tokens
- `deadline`: Transaction deadline timestamp

## 💡 Examples

### Deploy Contract

```solidity
// Deploy SimpleSwap for USDC/ETH pair
SimpleSwap pool = new SimpleSwap(
    0xA0b86a33E6441b8F2c5c0b36B4b8d1c8e9d3c7f2, // USDC
    0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2  // WETH
);
```

### Add Initial Liquidity

```solidity
// Approve tokens first
IERC20(tokenA).approve(address(pool), 1000 * 1e18);
IERC20(tokenB).approve(address(pool), 500 * 1e18);

// Add liquidity
pool.addLiquidity(
    tokenA,
    tokenB,
    1000 * 1e18,  // 1000 Token A
    500 * 1e18,   // 500 Token B
    900 * 1e18,   // Min 900 Token A
    450 * 1e18,   // Min 450 Token B
    msg.sender,
    block.timestamp + 300 // 5 minutes deadline
);
```

### Swap Tokens

```solidity
// Approve input token
IERC20(tokenA).approve(address(pool), 100 * 1e18);

// Swap 100 Token A for Token B
address[] memory path = new address[](2);
path[0] = tokenA;
path[1] = tokenB;

pool.swapExactTokensForTokens(
    100 * 1e18,      // 100 Token A input
    45 * 1e18,       // Min 45 Token B output
    path,
    msg.sender,
    block.timestamp + 300
);
```

## 🔒 Security Features

### Protections Implemented

1. **Reentrancy Guard**: Prevents recursive calls during operations
2. **Input Validation**: Comprehensive parameter checking
3. **Slippage Protection**: Minimum amount requirements
4. **Deadline Protection**: Transaction expiration timestamps
5. **Zero Address Checks**: Prevents transfers to burn addresses
6. **Token Validation**: Ensures operations use correct token pairs

### Modifiers

- `tokensValidation`: Validates token pair addresses
- `ensure(deadline)`: Enforces transaction deadlines
- `nonReentrant`: Prevents reentrancy attacks

## 📊 Mathematical Formulas

### Constant Product Formula
```
x * y = k (constant)
```
Where:
- `x` = Reserve of token A
- `y` = Reserve of token B
- `k` = Constant product

### Swap Calculation
```
amountOut = (amountIn * 997 * reserveOut) / (reserveIn * 1000 + amountIn * 997)
```

### Price Calculation
```
price = (reserveOut * 1e18) / reserveIn
```

## 🔍 Events

The contract emits the following events:

- `LiquidityAdded`: When liquidity is provided
- `LiquidityRemoved`: When liquidity is withdrawn
- `Swap`: When tokens are swapped

## ⚠️ Important Notes

1. **First Liquidity**: Initial liquidity provider should add balanced amounts
2. **Minimum Liquidity**: First 1,000 LP tokens are permanently locked
3. **Impermanent Loss**: Liquidity providers face impermanent loss risk
4. **Gas Costs**: Operations consume gas; consider transaction costs
5. **Slippage**: Large trades may experience significant slippage

## 🚨 Risks and Considerations

- **Smart Contract Risk**: Code may contain bugs or vulnerabilities
- **Impermanent Loss**: LP tokens may lose value relative to holding tokens
- **Slippage**: Large trades affect token prices significantly
- **Front-running**: MEV bots may front-run profitable trades
- **Liquidity Risk**: Low liquidity pools have higher slippage

## 📄 License

This project is licensed under the MIT License.

## 🤝 Contributing

Contributions are welcome! Please follow these steps:

1. Fork the repository
2. Create a feature branch
3. Commit your changes
4. Push to the branch
5. Create a Pull Request

## 🔗 Links

- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)
- [Uniswap V2 Documentation](https://docs.uniswap.org/contracts/v2/overview)
- [Solidity Documentation](https://docs.soliditylang.org/)

---

**Disclaimer**: This contract is for educational purposes. Always audit smart contracts before deploying to mainnet with real funds.
