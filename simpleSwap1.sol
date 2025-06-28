// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title SimpleSwap
 * @dev A decentralized exchange contract that replicates basic Uniswap 
 * @notice This contract allows users to add/remove liquidity and swap tokens using the constant product formula
 * @author Marcelo Montaño
 */
contract SimpleSwap is ReentrancyGuard {
    using Math for uint256;

    /// @dev Pool information structure
    /// @param reserveA Reserve amount of token A (sorted by address)
    /// @param reserveB Reserve amount of token B (sorted by address)  
    /// @param totalSupply Total liquidity tokens in circulation for this pool
    /// @param liquidityBalances Mapping of user addresses to their liquidity token balances
    /// @param exists Whether the pool has been initialized (prevents operations on non-existent pools)
    struct Pool {
        uint256 reserveA;        // Reserve of the token with lower address
        uint256 reserveB;        // Reserve of the token with higher address
        uint256 totalSupply;     // Total liquidity tokens minted for this pool
        mapping(address => uint256) liquidityBalances;  // User balances of liquidity tokens
        bool exists;             // Flag to check if pool is initialized
    }

    /// @dev Mapping from pool key hash to pool information
    /// Each token pair gets a unique hash as identifier
    mapping(bytes32 => Pool) public pools;
    
    /// @dev Trading fee factor (0.3% = 997/1000)
    /// This means 99.7% of the input amount is used for the swap calculation
    uint256 private constant FEE_FACTOR = 997;
    /// @dev Fee denominator for percentage calculations
    uint256 private constant FEE_DENOMINATOR = 1000;
    
    /// @dev Minimum liquidity locked permanently to prevent price manipulation
    /// The first 1000 liquidity tokens are burned to prevent attacks on small pools
    uint256 private constant MINIMUM_LIQUIDITY = 10**3;

    /// @notice Emitted when liquidity is added to a pool
    /// @param tokenA Address of the first token
    /// @param tokenB Address of the second token
    /// @param amountA Amount of tokenA added
    /// @param amountB Amount of tokenB added
    /// @param liquidity Amount of liquidity tokens minted
    /// @param to Address that received the liquidity tokens
    event LiquidityAdded(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address indexed to
    );
    
    /// @notice Emitted when liquidity is removed from a pool
    /// @param tokenA Address of the first token
    /// @param tokenB Address of the second token
    /// @param amountA Amount of tokenA withdrawn
    /// @param amountB Amount of tokenB withdrawn
    /// @param liquidity Amount of liquidity tokens burned
    /// @param to Address that received the tokens
    event LiquidityRemoved(
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity,
        address indexed to
    );
    
    /// @notice Emitted when tokens are swapped
    /// @param tokenIn Address of the input token
    /// @param tokenOut Address of the output token
    /// @param amountIn Amount of input tokens
    /// @param amountOut Amount of output tokens
    /// @param to Address that received the output tokens
    event Swap(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed to
    );

    /// @notice Ensures transaction is executed before deadline
    /// @param deadline Unix timestamp after which transaction will revert
    /// @dev This prevents transactions from being executed after user-specified time limits
    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "SimpleSwap: EXPIRED");
        _;
    }

    /**
     * @dev Generates a unique key for a token pair
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @return Unique hash key for the token pair
     * @notice This ensures that tokenA/tokenB and tokenB/tokenA pairs use the same pool
     */
    function _getPoolKey(address tokenA, address tokenB) private pure returns (bytes32) {
        // Sort tokens to ensure consistent pool key regardless of input order
        return tokenA < tokenB ? 
            keccak256(abi.encodePacked(tokenA, tokenB)) : 
            keccak256(abi.encodePacked(tokenB, tokenA));
    }

    /**
     * @dev Sorts token addresses to ensure consistent ordering
     * @param tokenA First token address
     * @param tokenB Second token address
     * @return token0 Token with lower address (becomes reserveA)
     * @return token1 Token with higher address (becomes reserveB)
     * @notice This prevents duplicate pools and ensures deterministic token ordering
     */
    function _sortTokens(address tokenA, address tokenB) 
        private 
        pure 
        returns (address token0, address token1) 
    {
        // Ensure tokens are different
        require(tokenA != tokenB, "SimpleSwap: IDENTICAL_ADDRESSES");
        
        // Sort by address value (lower address becomes token0)
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        // Ensure neither token is the zero address
        require(token0 != address(0), "SimpleSwap: ZERO_ADDRESS");
    }

    /**
     * @dev Calculates square root using Newton-Raphson method
     * @param y Input value to calculate square root for
     * @return z Square root of input value
     * @notice Used for calculating initial liquidity tokens: sqrt(amountA * amountB)
     */
    function _sqrt(uint256 y) private pure returns (uint256 z) {
        if (y > 3) {
            // Initialize with the input value
            z = y;
            // Start with a reasonable approximation
            uint256 x = y / 2 + 1;
            
            // Iterate until convergence using Newton-Raphson formula: x_new = (x + y/x) / 2
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            // For small values (1, 2, 3), return 1
            z = 1;
        }
        // For y = 0, z remains 0
    }

    /**
     * @notice Adds liquidity to a token pair pool
     * @dev Creates a new pool if it doesn't exist, otherwise adds proportional liquidity
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @param amountADesired Desired amount of tokenA to add
     * @param amountBDesired Desired amount of tokenB to add
     * @param amountAMin Minimum amount of tokenA to add (slippage protection)
     * @param amountBMin Minimum amount of tokenB to add (slippage protection)
     * @param to Address to receive liquidity tokens
     * @param deadline Unix timestamp deadline for transaction
     * @return amountA Actual amount of tokenA added
     * @return amountB Actual amount of tokenB added
     * @return liquidity Amount of liquidity tokens minted
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) 
        external 
        ensure(deadline) 
        nonReentrant 
        returns (uint256 amountA, uint256 amountB, uint256 liquidity) 
    {
        require(to != address(0), "SimpleSwap: ZERO_ADDRESS");
        
        // Sort tokens to ensure consistent pool handling
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        bytes32 poolKey = _getPoolKey(token0, token1);
        
        Pool storage pool = pools[poolKey];
        
        if (!pool.exists) {
            // FIRST LIQUIDITY DEPOSIT - Initialize new pool
            // Use exact desired amounts since there's no existing ratio to maintain
            amountA = amountADesired;
            amountB = amountBDesired;
            
            // Calculate initial liquidity using geometric mean: sqrt(amountA * amountB)
            // Subtract minimum liquidity to prevent manipulation of small pools
            liquidity = _sqrt(amountA * amountB) - MINIMUM_LIQUIDITY;
            
            // Mark pool as existing and set initial total supply
            pool.exists = true;
            pool.totalSupply = liquidity + MINIMUM_LIQUIDITY;
        } else {
            // POOL EXISTS - Add proportional liquidity to maintain price ratio
            
            // Get current reserves in the order of input tokens
            uint256 reserveA = tokenA == token0 ? pool.reserveA : pool.reserveB;
            uint256 reserveB = tokenA == token0 ? pool.reserveB : pool.reserveA;
            
            // Calculate optimal amount of tokenB based on desired tokenA amount
            // Formula: amountB = (amountA * reserveB) / reserveA
            uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
            
            if (amountBOptimal <= amountBDesired) {
                // We can use the desired tokenA amount
                require(amountBOptimal >= amountBMin, "SimpleSwap: INSUFFICIENT_B_AMOUNT");
                amountA = amountADesired;
                amountB = amountBOptimal;
            } else {
                // Calculate optimal amount of tokenA based on desired tokenB amount
                // Formula: amountA = (amountB * reserveA) / reserveB
                uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
                require(amountAOptimal <= amountADesired && amountAOptimal >= amountAMin, 
                       "SimpleSwap: INSUFFICIENT_A_AMOUNT");
                amountA = amountAOptimal;
                amountB = amountBDesired;
            }
            
            // Calculate liquidity tokens to mint based on proportion of contribution
            // Take minimum to ensure we don't mint more than either token proportion allows
            liquidity = Math.min(
                (amountA * pool.totalSupply) / reserveA,
                (amountB * pool.totalSupply) / reserveB
            );
        }
        
        require(liquidity > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY_MINTED");
        
        // Transfer tokens from user to this contract
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountB);
        
        // Update pool reserves (maintain sorted order)
        if (tokenA == token0) {
            pool.reserveA += amountA;
            pool.reserveB += amountB;
        } else {
            pool.reserveA += amountB;  // tokenB becomes reserveA
            pool.reserveB += amountA;  // tokenA becomes reserveB
        }
        
        // Mint liquidity tokens to the specified recipient
        pool.liquidityBalances[to] += liquidity;
        pool.totalSupply += liquidity;
        
        emit LiquidityAdded(tokenA, tokenB, amountA, amountB, liquidity, to);
    }

    /**
     * @notice Removes liquidity from a token pair pool
     * @dev Burns liquidity tokens and returns proportional amounts of both tokens
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @param liquidity Amount of liquidity tokens to burn
     * @param amountAMin Minimum amount of tokenA to receive (slippage protection)
     * @param amountBMin Minimum amount of tokenB to receive (slippage protection)
     * @param to Address to receive withdrawn tokens
     * @param deadline Unix timestamp deadline for transaction
     * @return amountA Amount of tokenA withdrawn
     * @return amountB Amount of tokenB withdrawn
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) 
        external 
        ensure(deadline) 
        nonReentrant 
        returns (uint256 amountA, uint256 amountB) 
    {
        require(to != address(0), "SimpleSwap: ZERO_ADDRESS");
        
        // Sort tokens and get pool reference
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        bytes32 poolKey = _getPoolKey(token0, token1);
        
        Pool storage pool = pools[poolKey];
        require(pool.exists, "SimpleSwap: POOL_NOT_EXISTS");
        require(pool.liquidityBalances[msg.sender] >= liquidity, "SimpleSwap: INSUFFICIENT_LIQUIDITY");
        
        // Calculate proportional token amounts to return
        // Formula: amount = (liquidity * reserve) / totalSupply
        amountA = tokenA == token0 ? 
            (liquidity * pool.reserveA) / pool.totalSupply :
            (liquidity * pool.reserveB) / pool.totalSupply;
            
        amountB = tokenA == token0 ? 
            (liquidity * pool.reserveB) / pool.totalSupply :
            (liquidity * pool.reserveA) / pool.totalSupply;
        
        // Ensure minimum amounts are met (slippage protection)
        require(amountA >= amountAMin, "SimpleSwap: INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "SimpleSwap: INSUFFICIENT_B_AMOUNT");
        
        // Burn liquidity tokens from user's balance
        pool.liquidityBalances[msg.sender] -= liquidity;
        pool.totalSupply -= liquidity;
        
        // Update pool reserves (subtract withdrawn amounts)
        if (tokenA == token0) {
            pool.reserveA -= amountA;
            pool.reserveB -= amountB;
        } else {
            pool.reserveA -= amountB;  // tokenB was stored as reserveA
            pool.reserveB -= amountA;  // tokenA was stored as reserveB
        }
        
        // Transfer tokens to the specified recipient
        IERC20(tokenA).transfer(to, amountA);
        IERC20(tokenB).transfer(to, amountB);
        
        emit LiquidityRemoved(tokenA, tokenB, amountA, amountB, liquidity, to);
    }

    /**
     * @notice Swaps an exact amount of input tokens for output tokens
     * @dev Uses constant product formula with 0.3% trading fee
     * @param amountIn Exact amount of input tokens to swap
     * @param amountOutMin Minimum amount of output tokens to receive (slippage protection)
     * @param path Array of token addresses [tokenIn, tokenOut]
     * @param to Address to receive output tokens
     * @param deadline Unix timestamp deadline for transaction
     * @return amounts Array containing [amountIn, amountOut]
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) 
        external 
        ensure(deadline) 
        nonReentrant 
        returns (uint256[] memory amounts) 
    {
        require(path.length == 2, "SimpleSwap: INVALID_PATH");
        require(to != address(0), "SimpleSwap: ZERO_ADDRESS");
        
        // Get sorted tokens and pool reference
        (address token0, address token1) = _sortTokens(path[0], path[1]);
        Pool storage pool = pools[_getPoolKey(token0, token1)];
        require(pool.exists, "SimpleSwap: POOL_NOT_EXISTS");
        
        // Execute swap logic within scope to avoid "stack too deep" error
        {
            // Determine which reserve corresponds to input/output tokens
            uint256 reserveIn = path[0] == token0 ? pool.reserveA : pool.reserveB;
            uint256 reserveOut = path[0] == token0 ? pool.reserveB : pool.reserveA;
            
            // Calculate output amount using constant product formula with fees
            uint256 amountOut = getAmountOut(amountIn, reserveIn, reserveOut);
            
            // Ensure minimum output amount is met (slippage protection)
            require(amountOut >= amountOutMin, "SimpleSwap: INSUFFICIENT_OUTPUT_AMOUNT");
            
            // Transfer input tokens from user to this contract
            IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
            
            // Update pool reserves: increase input reserve, decrease output reserve
            if (path[0] == token0) {
                pool.reserveA += amountIn;   // Add input tokens to reserve
                pool.reserveB -= amountOut;  // Remove output tokens from reserve
            } else {
                pool.reserveA -= amountOut;  // Remove output tokens from reserve
                pool.reserveB += amountIn;   // Add input tokens to reserve
            }
            
            // Transfer output tokens to the specified recipient
            IERC20(path[1]).transfer(to, amountOut);
            
            // Prepare return array with input and output amounts
            amounts = new uint256[](2);
            amounts[0] = amountIn;
            amounts[1] = amountOut;
            
            emit Swap(path[0], path[1], amountIn, amountOut, to);
        }
    }

    /**
     * @notice Gets the current price of tokenA in terms of tokenB
     * @dev Price is calculated as reserveB / reserveA with 18 decimal precision
     * @param tokenA Address of the base token (what we're pricing)
     * @param tokenB Address of the quote token (what we're pricing in)
     * @return price Price of tokenA in terms of tokenB (scaled by 1e18)
     * @notice Example: If 1 tokenA = 2 tokenB, this returns 2 * 1e18
     */
    function getPrice(address tokenA, address tokenB) 
        external 
        view 
        returns (uint256 price) 
    {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        bytes32 poolKey = _getPoolKey(token0, token1);
        
        Pool storage pool = pools[poolKey];
        require(pool.exists, "SimpleSwap: POOL_NOT_EXISTS");
        
        // Get reserves in the order of input tokens
        uint256 reserveA = tokenA == token0 ? pool.reserveA : pool.reserveB;
        uint256 reserveB = tokenA == token0 ? pool.reserveB : pool.reserveA;
        
        require(reserveA > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY");
        
        // Calculate price with 18 decimal precision
        // Price = (amount of tokenB) / (amount of tokenA) * 1e18
        price = (reserveB * 1e18) / reserveA;
    }

    /**
     * @notice Calculates the amount of output tokens for a given input amount
     * @dev Uses constant product formula: (x + Δx) * (y - Δy) = x * y, accounting for trading fees
     * @param amountIn Amount of input tokens
     * @param reserveIn Current reserve of input token in the pool
     * @param reserveOut Current reserve of output token in the pool
     * @return amountOut Amount of output tokens that will be received
     * @notice Formula derivation:
     *   - Constant product: x * y = k
     *   - After swap: (x + amountIn * 0.997) * (y - amountOut) = k
     *   - Solving for amountOut: amountOut = (amountIn * 0.997 * y) / (x + amountIn * 0.997)
     */
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) 
        public 
        pure 
        returns (uint256 amountOut) 
    {
        require(amountIn > 0, "SimpleSwap: INSUFFICIENT_INPUT_AMOUNT");
        require(reserveIn > 0 && reserveOut > 0, "SimpleSwap: INSUFFICIENT_LIQUIDITY");
        
        // Apply trading fee (0.3% fee means 99.7% of input is used for calculation)
        uint256 amountInWithFee = amountIn * FEE_FACTOR;  // amountIn * 997
        
        // Calculate numerator: (amountIn * 997) * reserveOut
        uint256 numerator = amountInWithFee * reserveOut;
        
        // Calculate denominator: (reserveIn * 1000) + (amountIn * 997)
        uint256 denominator = (reserveIn * FEE_DENOMINATOR) + amountInWithFee;
        
        // Final calculation: amountOut = numerator / denominator
        amountOut = numerator / denominator;
    }

    /**
     * @notice Gets the current reserves of a token pair
     * @dev Returns reserves in the same order as the input tokens
     * @param tokenA Address of the first token
     * @param tokenB Address of the second token
     * @return reserveA Current reserve of tokenA in the pool
     * @return reserveB Current reserve of tokenB in the pool
     */
    function getReserves(address tokenA, address tokenB) 
        external 
        view 
        returns (uint256 reserveA, uint256 reserveB) 
    {
        (address token0, address token1) = _sortTokens(tokenA, tokenB);
        bytes32 poolKey = _getPoolKey(token0, token1);
        
        Pool storage pool = pools[poolKey];
        require(pool.exists, "SimpleSwap: POOL_NOT_EXISTS");
        
        // Return reserves in the order of input tokens (not sorted order)
        reserveA = tokenA == token0 ? pool.reserveA : pool.reserveB;
        reserveB = tokenA == token0 ? pool.reserveB : pool.reserveA;
    }

    /**
     * @notice Gets the liquidity token balance of a user for a specific pool
     * @dev Returns the amount of liquidity tokens owned by the user
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     * @param user Address of the user to query
     * @return balance Amount of liquidity tokens owned by the user
     */
    function getLiquidityBalance(address tokenA, address tokenB, address user) 
        external 
        view 
        returns (uint256 balance) 
    {
        bytes32 poolKey = _getPoolKey(tokenA, tokenB);
        balance = pools[poolKey].liquidityBalances[user];
    }

    /**
     * @notice Gets the total supply of liquidity tokens for a specific pool
     * @dev Returns the total amount of liquidity tokens in circulation
     * @param tokenA Address of the first token in the pair
     * @param tokenB Address of the second token in the pair
     * @return totalSupply Total amount of liquidity tokens in circulation
     */
    function getTotalSupply(address tokenA, address tokenB) 
        external 
        view 
        returns (uint256 totalSupply) 
    {
        bytes32 poolKey = _getPoolKey(tokenA, tokenB);
        totalSupply = pools[poolKey].totalSupply;
    }
}