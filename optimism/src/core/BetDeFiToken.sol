// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@layerzerolabs/solidity-examples/contracts/interfaces/ILayerZeroEndpoint.sol";
import "@layerzerolabs/solidity-examples/contracts/interfaces/ILayerZeroReceiver.sol";

/**
 * @title BetDeFiToken
 * @dev Implementation of the BetDeFiToken
 */
contract BetDeFiToken is 
    Initializable, 
    ERC20Upgradeable, 
    PausableUpgradeable, 
    OwnableUpgradeable, 
    ReentrancyGuardUpgradeable,
    ILayerZeroReceiver 
{
    // State variables
    address public feePool;
    address public liquidityPool;
    ILayerZeroEndpoint public lzEndpoint;
    
    uint256 public purchaseFee; // basis points (1/100 of 1%)
    uint256 public transferFee;
    uint256 public bridgeFee;
    
    uint256 public constant INITIAL_PRICE = 0.001 ether;    // Starting price
    uint256 public constant MAX_SUPPLY = 1000000 * 10**18;  // 1 million tokens
    uint256 public constant PRICE_MULTIPLIER = 125;         // 25% increase per 100k tokens
    uint256 public constant CURVE_DIVISOR = 100000 * 10**18;// Supply increment that causes price increase
    
    // Protocol Reserve Configuration
    uint256 public reserveRatio;      // Reserve ratio in ppm (parts per million)
    uint256 public virtualBalance;     // Virtual balance for price stability
    uint256 public virtualSupply;      // Virtual supply for price stability
    
    mapping(uint16 => bytes) public trustedRemoteLookup;
    mapping(uint16 => uint256) public minGasLookup;
    
    // Events
    event TokensPurchased(address indexed buyer, uint256 amount, uint256 fee);
    event TokensSold(address indexed seller, uint256 amount, uint256 ethReturn, uint256 fee);
    event BridgeInitiated(address indexed from, uint256 amount, uint16 chainId);
    event BridgeCompleted(address indexed to, uint256 amount, uint16 chainId);
    event FeePoolUpdated(address indexed newFeePool);
    event LiquidityPoolUpdated(address indexed newLiquidityPool);
    event FeesUpdated(uint256 purchaseFee, uint256 transferFee, uint256 bridgeFee);
    event TrustedRemoteUpdated(uint16 indexed chainId, bytes path);
    event MinGasUpdated(uint16 indexed chainId, uint256 minGas);
    event CurveParametersUpdated(uint256 reserveRatio, uint256 virtualBalance, uint256 virtualSupply);

    // Errors
    error InvalidFeePool();
    error InvalidLiquidityPool();
    error InvalidAmount();
    error InsufficientBalance();
    error UnauthorizedEndpoint();
    error InvalidSource();
    error BridgeError();
    error InvalidFeeAmount();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @dev Initializes the contract
     * @param name Token name
     * @param symbol Token symbol
     * @param _lzEndpoint LayerZero endpoint address
     * @param _feePool Fee pool address
     * @param _liquidityPool Liquidity pool address
     */
    function initialize(
        string memory name,
        string memory symbol,
        address _lzEndpoint,
        address _feePool,
        address _liquidityPool
    ) public initializer {
        __ERC20_init(name, symbol);
        __Pausable_init();
        __Ownable_init();
        __ReentrancyGuard_init();

        if (_feePool == address(0)) revert InvalidFeePool();
        if (_liquidityPool == address(0)) revert InvalidLiquidityPool();
        
        lzEndpoint = ILayerZeroEndpoint(_lzEndpoint);
        feePool = _feePool;
        liquidityPool = _liquidityPool;
        
        // Set default fees (in basis points)
        purchaseFee = 60; // 0.6%
        transferFee = 10;  // 0.1%
        bridgeFee = 30;   // 0.3%
        
        // Initialize price curve parameters
        reserveRatio = 500000;    // 50% reserve ratio
        virtualBalance = 100 ether; // Initial virtual balance
        virtualSupply = 100000 * 10**18; // Initial virtual supply
    }

    /**
     * @dev Purchases tokens with native currency
     */
    /**
     * @dev Calculates the current token price based on supply
     * @return Current price per token in wei
     */
    function getCurrentPrice() public view returns (uint256) {
        uint256 totalSupply = totalSupply();
        
        // Bonding curve formula: price = initial_price * (1 + supply/curve_divisor)^price_multiplier
        uint256 supplyFactor = ((totalSupply + virtualSupply) * 1e18) / CURVE_DIVISOR;
        uint256 priceMultiple = (100 + ((supplyFactor * PRICE_MULTIPLIER) / 1e18));
        
        return (INITIAL_PRICE * priceMultiple) / 100;
    }

    /**
     * @dev Calculates the cost for a specific amount of tokens
     * @param amount Amount of tokens to purchase
     * @return totalCost Total cost in ETH
     */
    function calculatePurchaseCost(uint256 amount) public view returns (uint256 totalCost) {
        require(amount > 0, "Invalid amount");
        
        uint256 supplyAfter = totalSupply() + amount;
        require(supplyAfter <= MAX_SUPPLY, "Exceeds max supply");

        // Calculate integral of the bonding curve for the amount
        uint256 currentSupply = totalSupply() + virtualSupply;
        uint256 newSupply = currentSupply + amount;
        
        uint256 avgPrice = (getCurrentPrice() + 
            (INITIAL_PRICE * (100 + ((newSupply * PRICE_MULTIPLIER) / CURVE_DIVISOR))) / 100) / 2;
            
        totalCost = (avgPrice * amount) / 1e18;
    }

    /**
     * @dev Calculates the amount of tokens that can be bought with a specific amount of ETH
     * @param ethAmount Amount of ETH to spend
     * @return tokenAmount Amount of tokens that can be purchased
     */
    function calculatePurchaseAmount(uint256 ethAmount) public view returns (uint256 tokenAmount) {
        require(ethAmount > 0, "Invalid ETH amount");
        
        uint256 currentPrice = getCurrentPrice();
        tokenAmount = (ethAmount * 1e18) / currentPrice;
        
        // Verify against max supply
        require(totalSupply() + tokenAmount <= MAX_SUPPLY, "Exceeds max supply");
    }

    /**
     * @dev Purchases tokens with native currency (ETH)
     * @param minTokens Minimum amount of tokens to receive (slippage protection)
     */
    function purchaseTokens(uint256 minTokens) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        // Calculate tokens to receive based on ETH sent
        uint256 tokenAmount = calculatePurchaseAmount(msg.value);
        require(tokenAmount >= minTokens, "Slippage too high");
        
        // Calculate purchase fee
        uint256 fee = (tokenAmount * purchaseFee) / 10000;
        uint256 netAmount = tokenAmount - fee;
        
        // Update virtual balance and supply
        virtualBalance += msg.value;
        virtualSupply += tokenAmount;
        
        // Mint tokens
        _mint(msg.sender, netAmount);
        _mint(feePool, fee);
        
        // Forward ETH to liquidity pool
        (bool success, ) = liquidityPool.call{value: msg.value}("");
        require(success, "ETH transfer failed");
        
        emit TokensPurchased(msg.sender, netAmount, fee);
    }

    /**
     * @dev Sells tokens back to the protocol
     * @param amount Amount of tokens to sell
     * @param minEthReturn Minimum ETH to receive (slippage protection)
     */
    function sellTokens(uint256 amount, uint256 minEthReturn)
        external
        nonReentrant
        whenNotPaused
    {
        require(amount > 0, "Invalid amount");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        
        // Calculate ETH return based on bonding curve
        uint256 currentSupply = totalSupply() + virtualSupply;
        uint256 newSupply = currentSupply - amount;
        
        uint256 avgPrice = (getCurrentPrice() + 
            (INITIAL_PRICE * (100 + ((newSupply * PRICE_MULTIPLIER) / CURVE_DIVISOR))) / 100) / 2;
            
        uint256 ethReturn = (avgPrice * amount) / 1e18;
        require(ethReturn >= minEthReturn, "Slippage too high");
        
        // Calculate sell fee
        uint256 fee = (ethReturn * purchaseFee) / 10000;
        uint256 netReturn = ethReturn - fee;
        
        // Update virtual balance and supply
        virtualBalance -= netReturn;
        virtualSupply -= amount;
        
        // Burn tokens
        _burn(msg.sender, amount);
        
        // Transfer ETH to seller
        (bool success, ) = msg.sender.call{value: netReturn}("");
        require(success, "ETH transfer failed");
        
        // Transfer fee to fee pool
        (success, ) = feePool.call{value: fee}("");
        require(success, "Fee transfer failed");
        
        emit TokensSold(msg.sender, amount, netReturn, fee);
    }
    
    /**
     * @dev Updates the reserve ratio and virtual balance/supply parameters
     * Can only be called by owner and should be used carefully
     */
    function updateCurveParameters(
        uint256 newReserveRatio,
        uint256 newVirtualBalance,
        uint256 newVirtualSupply
    ) external onlyOwner {
        require(newReserveRatio <= 1000000, "Invalid reserve ratio"); // max 100%
        reserveRatio = newReserveRatio;
        virtualBalance = newVirtualBalance;
        virtualSupply = newVirtualSupply;
        
        emit CurveParametersUpdated(newReserveRatio, newVirtualBalance, newVirtualSupply);
    }

    /**
     * @dev Initiates bridge transfer to Solana
     * @param amount Amount of tokens to bridge
     * @param dstChainId Destination chain ID
     */
    function bridgeToSolana(uint256 amount, uint16 dstChainId) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        if (amount == 0) revert InvalidAmount();
        if (balanceOf(msg.sender) < amount) revert InsufficientBalance();
        
        bytes memory trustedRemote = trustedRemoteLookup[dstChainId];
        if (trustedRemote.length == 0) revert InvalidSource();
        
        uint256 fee = (amount * bridgeFee) / 10000;
        uint256 netAmount = amount - fee;
        
        // Encode the payload
        bytes memory payload = abi.encode(msg.sender, netAmount);
        
        // Get the fees needed for LayerZero
        (uint256 messageFee,) = lzEndpoint.estimateFees(
            dstChainId,
            address(this),
            payload,
            false,
            bytes("")
        );
        
        if (msg.value < messageFee) revert BridgeError();
        
        // Burn tokens from sender and send fee to fee pool
        _burn(msg.sender, amount);
        _mint(feePool, fee);
        
        // Send LayerZero message
        lzEndpoint.send{value: msg.value}(
            dstChainId,
            trustedRemote,
            payload,
            payable(msg.sender),
            address(0),
            bytes("")
        );
        
        emit BridgeInitiated(msg.sender, netAmount, dstChainId);
    }

    /**
     * @dev Receives messages from LayerZero
     */
    function lzReceive(
        uint16 srcChainId,
        bytes memory srcAddress,
        uint64 nonce,
        bytes memory payload
    ) external override {
        if (msg.sender != address(lzEndpoint)) revert UnauthorizedEndpoint();
        
        bytes memory trustedRemote = trustedRemoteLookup[srcChainId];
        if (trustedRemote.length == 0 || keccak256(srcAddress) != keccak256(trustedRemote)) {
            revert InvalidSource();
        }
        
        (address toAddress, uint256 amount) = abi.decode(payload, (address, uint256));
        
        _mint(toAddress, amount);
        
        emit BridgeCompleted(toAddress, amount, srcChainId);
    }

    /**
     * @dev Updates the fee pool address
     */
    function setFeePool(address _feePool) external onlyOwner {
        if (_feePool == address(0)) revert InvalidFeePool();
        feePool = _feePool;
        emit FeePoolUpdated(_feePool);
    }

    /**
     * @dev Updates the liquidity pool address
     */
    function setLiquidityPool(address _liquidityPool) external onlyOwner {
        if (_liquidityPool == address(0)) revert InvalidLiquidityPool();
        liquidityPool = _liquidityPool;
        emit LiquidityPoolUpdated(_liquidityPool);
    }

    /**
     * @dev Updates fee percentages
     */
    function updateFees(
        uint256 _purchaseFee,
        uint256 _transferFee,
        uint256 _bridgeFee
    ) external onlyOwner {
        if (_purchaseFee > 1000 || _transferFee > 1000 || _bridgeFee > 1000) {
            revert InvalidFeeAmount();
        }
        purchaseFee = _purchaseFee;
        transferFee = _transferFee;
        bridgeFee = _bridgeFee;
        emit FeesUpdated(_purchaseFee, _transferFee, _bridgeFee);
    }

    /**
     * @dev Sets the trusted remote address for a chain ID
     */
    function setTrustedRemote(uint16 chainId, bytes calldata path) external onlyOwner {
        trustedRemoteLookup[chainId] = path;
        emit TrustedRemoteUpdated(chainId, path);
    }

    /**
     * @dev Sets the minimum gas limit for a chain ID
     */
    function setMinGas(uint16 chainId, uint256 minGas) external onlyOwner {
        minGasLookup[chainId] = minGas;
        emit MinGasUpdated(chainId, minGas);
    }

    /**
     * @dev Override of the transfer function to include fee handling
     */
    function transfer(address to, uint256 amount) 
        public 
        virtual 
        override 
        returns (bool) 
    {
        if (amount == 0) revert InvalidAmount();
        
        uint256 fee = (amount * transferFee) / 10000;
        uint256 netAmount = amount - fee;
        
        super.transfer(feePool, fee);
        super.transfer(to, netAmount);
        
        return true;
    }

    /**
     * @dev Override of the transferFrom function to include fee handling
     */
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) public virtual override returns (bool) {
        if (amount == 0) revert InvalidAmount();
        
        uint256 fee = (amount * transferFee) / 10000;
        uint256 netAmount = amount - fee;
        
        super.transferFrom(from, feePool, fee);
        super.transferFrom(from, to, netAmount);
        
        return true;
    }

    /**
     * @dev Pauses all token transfers
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @dev Unpauses all token transfers
     */
    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @dev Function to receive Ether
     */
    receive() external payable {}
}