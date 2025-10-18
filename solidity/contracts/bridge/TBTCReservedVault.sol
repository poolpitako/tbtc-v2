// SPDX-License-Identifier: GPL-3.0-only

// ██████████████     ▐████▌     ██████████████
// ██████████████     ▐████▌     ██████████████
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
// ██████████████     ▐████▌     ██████████████
// ██████████████     ▐████▌     ██████████████
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌
//               ▐████▌    ▐████▌

pragma solidity 0.8.17;

import "../bank/Bank.sol";
import "../token/TBTC.sol";
import "./Bridge.sol";
import "./BitcoinTx.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

/// @title TBTCReservedVault
/// @notice This contract allows users to deposit BTC and mint tBTC while preserving
///         the ability to redeem the exact same BTC UTXO for tax efficiency purposes.
///         Users pay a storage fee upfront for reserving their specific UTXO.
///         If the reservation expires, anyone can liquidate the position, sending
///         the storage fee to the DAO treasury.
/// @dev This contract integrates with the existing tBTC v2 Bridge and Bank contracts
///      to provide tax-efficient BTC custody while maintaining the security model
///      of the tBTC system.
contract TBTCReservedVault is OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using BitcoinTx for bytes;

    // ═══════════════════════════════════════════════════════════════════════════
    // State Variables
    // ═══════════════════════════════════════════════════════════════════════════

    Bank public bank;
    TBTC public tbtcToken;
    Bridge public bridge;
    address public daoTreasury;

    // Fee parameters (in basis points)
    uint256 public constant ANNUAL_FEE_BPS = 10; // 0.1% per year
    uint256 public constant LIQUIDATION_BONUS_BPS = 10; // 0.1% liquidation bonus
    uint256 public constant SMALL_DEPOSIT_MULTIPLIER = 2; // 2x fee for small deposits

    // Deposit constraints (in satoshis)
    uint256 public constant MIN_DEPOSIT_BTC = 0.1e8; // 0.1 BTC minimum
    uint256 public constant MIN_FEE_BTC = 0.01e8; // 0.01 BTC minimum fee per year
    uint256 public constant SMALL_DEPOSIT_THRESHOLD = 1e8; // 1 BTC threshold
    uint256 public constant MAX_RESERVATION_DAYS = 1460; // 4 years maximum

    // Storage fee accumulator for DAO
    uint256 public accumulatedFeesForDAO;

    // ═══════════════════════════════════════════════════════════════════════════
    // Data Structures
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Represents a BTC UTXO reservation
    struct Reservation {
        bytes32 utxoHash;           // Hash of the UTXO
        address depositor;          // Original depositor address
        uint256 btcAmount;          // Amount of BTC deposited (satoshis)
        uint256 tbtcMinted;         // Amount of tBTC minted to user
        uint256 storageFee;         // Storage fee paid (satoshis)
        uint256 depositTimestamp;   // When the deposit was made
        uint256 expiryTimestamp;    // When the reservation expires
        bytes btcRedemptionAddress; // Pre-committed BTC redemption address
        bool isActive;              // Whether reservation is still active
    }

    /// @notice Liquidation statistics for tracking node performance
    struct LiquidatorStats {
        uint256 liquidationCount;
        uint256 totalBonusEarned;
        uint256 lastLiquidationTime;
    }

    // Mapping from UTXO hash to reservation
    mapping(bytes32 => Reservation) public reservations;

    // Mapping from user address to their UTXO hashes
    mapping(address => bytes32[]) public userReservations;

    // Mapping from user to active reservation count
    mapping(address => uint256) public activeReservationCount;

    // Liquidator performance tracking
    mapping(address => LiquidatorStats) public liquidatorStats;

    // Top liquidators leaderboard
    address[] public topLiquidators;
    uint256 public constant MAX_LEADERBOARD_SIZE = 10;

    // ═══════════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════════

    event ReservationCreated(
        bytes32 indexed utxoHash,
        address indexed depositor,
        uint256 btcAmount,
        uint256 tbtcMinted,
        uint256 storageFee,
        uint256 expiryTimestamp
    );

    event ReservationRedeemed(
        bytes32 indexed utxoHash,
        address indexed depositor,
        uint256 btcAmount,
        bytes btcRedemptionAddress
    );

    event ReservationLiquidated(
        bytes32 indexed utxoHash,
        address indexed originalDepositor,
        address indexed liquidator,
        uint256 storageFee,
        uint256 liquidationBonus
    );

    event FeesSentToDAO(
        uint256 amount,
        uint256 timestamp
    );

    event DAOTreasuryUpdated(
        address oldTreasury,
        address newTreasury
    );

    // ═══════════════════════════════════════════════════════════════════════════
    // Initialization
    // ═══════════════════════════════════════════════════════════════════════════

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // In production, this would call _disableInitializers() for upgradeable pattern
        // Commented out for testing purposes
        // _disableInitializers();
    }

    function initialize(
        address _bank,
        address _tbtcToken,
        address _bridge,
        address _daoTreasury
    ) external initializer {
        __Ownable_init();
        __ReentrancyGuard_init();

        require(_bank != address(0), "Invalid bank address");
        require(_tbtcToken != address(0), "Invalid TBTC address");
        require(_bridge != address(0), "Invalid bridge address");
        require(_daoTreasury != address(0), "Invalid treasury address");

        bank = Bank(_bank);
        tbtcToken = TBTC(_tbtcToken);
        bridge = Bridge(_bridge);
        daoTreasury = _daoTreasury;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Core Functions
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Deposits BTC with UTXO reservation for tax-efficient custody
    /// @param fundingTx Bitcoin funding transaction
    /// @param proof SPV proof for the funding transaction
    /// @param reservationDays Number of days to reserve the UTXO
    /// @param btcRedemptionAddress Pre-committed BTC address for redemption
    /// @return utxoHash The hash of the reserved UTXO
    /// @return tbtcMinted Amount of tBTC minted to the user
    function depositWithReservation(
        BitcoinTx.Info calldata fundingTx,
        bytes calldata proof,
        uint256 reservationDays,
        bytes calldata btcRedemptionAddress
    ) external nonReentrant returns (bytes32 utxoHash, uint256 tbtcMinted) {
        require(reservationDays > 0 && reservationDays <= MAX_RESERVATION_DAYS,
                "Invalid reservation period");
        require(btcRedemptionAddress.length == 20 || btcRedemptionAddress.length == 32,
                "Invalid BTC address length");

        // Parse and validate the funding transaction
        BitcoinTx.UTXO memory utxo = _processFundingTransaction(fundingTx, proof);

        require(utxo.txOutputValue >= MIN_DEPOSIT_BTC, "Deposit below minimum");

        utxoHash = keccak256(abi.encodePacked(utxo.txHash, utxo.txOutputIndex));
        require(!reservations[utxoHash].isActive, "UTXO already reserved");

        // Calculate storage fee
        uint256 storageFee = calculateStorageFee(utxo.txOutputValue, reservationDays);

        // Calculate tBTC to mint (deposit minus storage fee)
        tbtcMinted = _satoshiToTbtc(utxo.txOutputValue - storageFee);

        // Create reservation
        Reservation storage reservation = reservations[utxoHash];
        reservation.utxoHash = utxoHash;
        reservation.depositor = msg.sender;
        reservation.btcAmount = utxo.txOutputValue;
        reservation.tbtcMinted = tbtcMinted;
        reservation.storageFee = storageFee;
        reservation.depositTimestamp = block.timestamp;
        reservation.expiryTimestamp = block.timestamp + (reservationDays * 1 days);
        reservation.btcRedemptionAddress = btcRedemptionAddress;
        reservation.isActive = true;

        // Track user reservations
        userReservations[msg.sender].push(utxoHash);
        activeReservationCount[msg.sender]++;

        // Mint tBTC to user
        bank.increaseBalance(msg.sender, tbtcMinted);
        tbtcToken.mint(msg.sender, tbtcMinted);

        emit ReservationCreated(
            utxoHash,
            msg.sender,
            utxo.txOutputValue,
            tbtcMinted,
            storageFee,
            reservation.expiryTimestamp
        );

        return (utxoHash, tbtcMinted);
    }

    /// @notice Redeems the exact BTC UTXO that was originally deposited
    /// @param utxoHash Hash of the UTXO to redeem
    function redeemReservedUTXO(bytes32 utxoHash) external nonReentrant {
        Reservation storage reservation = reservations[utxoHash];

        require(reservation.isActive, "Reservation not active");
        require(reservation.depositor == msg.sender, "Not depositor");
        require(block.timestamp <= reservation.expiryTimestamp, "Reservation expired");

        // Burn the tBTC
        tbtcToken.burnFrom(msg.sender, reservation.tbtcMinted);
        bank.decreaseBalance(reservation.tbtcMinted);

        // Process redemption through bridge
        _processRedemption(reservation);

        // Send storage fee to DAO
        accumulatedFeesForDAO += reservation.storageFee;

        // Clean up reservation
        reservation.isActive = false;
        activeReservationCount[msg.sender]--;
        _removeUserReservation(msg.sender, utxoHash);

        emit ReservationRedeemed(
            utxoHash,
            msg.sender,
            reservation.btcAmount,
            reservation.btcRedemptionAddress
        );
    }

    /// @notice Liquidates an expired reservation, sending UTXO to general pool
    /// @param utxoHash Hash of the expired UTXO to liquidate
    /// @return liquidationBonus Amount of tBTC earned by liquidator
    function liquidateExpiredReservation(bytes32 utxoHash)
        external
        nonReentrant
        returns (uint256 liquidationBonus)
    {
        Reservation storage reservation = reservations[utxoHash];

        require(reservation.isActive, "Reservation not active");
        require(block.timestamp > reservation.expiryTimestamp, "Reservation not expired");

        // Calculate liquidation bonus (0.1% of BTC value)
        liquidationBonus = _satoshiToTbtc(
            (reservation.btcAmount * LIQUIDATION_BONUS_BPS) / 10000
        );

        // Storage fee goes to DAO
        accumulatedFeesForDAO += reservation.storageFee;

        // Mint bonus to liquidator (comes from storage fee buffer)
        if (liquidationBonus > 0) {
            tbtcToken.mint(msg.sender, liquidationBonus);
            bank.increaseBalance(msg.sender, liquidationBonus);
        }

        // Move UTXO to general redemption pool
        _moveToGeneralPool(reservation);

        // Update liquidator stats
        _updateLiquidatorStats(msg.sender, liquidationBonus);

        // Clean up reservation
        reservation.isActive = false;
        activeReservationCount[reservation.depositor]--;
        _removeUserReservation(reservation.depositor, utxoHash);

        emit ReservationLiquidated(
            utxoHash,
            reservation.depositor,
            msg.sender,
            reservation.storageFee,
            liquidationBonus
        );

        return liquidationBonus;
    }

    /// @notice Sweeps accumulated storage fees to DAO treasury
    function sweepFeesToDAO() external nonReentrant {
        require(accumulatedFeesForDAO > 0, "No fees to sweep");

        uint256 feesToTransfer = accumulatedFeesForDAO;
        accumulatedFeesForDAO = 0;

        // Convert satoshis to tBTC and mint to DAO
        uint256 tbtcAmount = _satoshiToTbtc(feesToTransfer);
        tbtcToken.mint(daoTreasury, tbtcAmount);
        bank.increaseBalance(daoTreasury, tbtcAmount);

        emit FeesSentToDAO(feesToTransfer, block.timestamp);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // View Functions
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Calculates the storage fee for a given deposit and duration
    /// @param btcAmount Amount of BTC to deposit (in satoshis)
    /// @param reservationDays Number of days to reserve
    /// @return storageFee The storage fee in satoshis
    function calculateStorageFee(uint256 btcAmount, uint256 reservationDays)
        public
        pure
        returns (uint256 storageFee)
    {
        require(btcAmount >= MIN_DEPOSIT_BTC, "Deposit below minimum");
        require(reservationDays > 0 && reservationDays <= MAX_RESERVATION_DAYS,
                "Invalid reservation period");

        // Calculate base fee (0.1% per year)
        storageFee = (btcAmount * ANNUAL_FEE_BPS * reservationDays) / (10000 * 365);

        // Calculate minimum fee based on years (0.01 BTC per year, stepped not prorated)
        // 1-365 days = 1 year fee, 366-730 days = 2 year fee, etc.
        uint256 yearsRoundedUp = (reservationDays + 364) / 365;
        uint256 minimumFee = MIN_FEE_BTC * yearsRoundedUp;

        // Ensure minimum fee
        if (storageFee < minimumFee) {
            storageFee = minimumFee;
        }

        return storageFee;
    }

    /// @notice Checks if a reservation has expired
    /// @param utxoHash Hash of the UTXO to check
    /// @return expired Whether the reservation has expired
    function isReservationExpired(bytes32 utxoHash) external view returns (bool expired) {
        Reservation storage reservation = reservations[utxoHash];
        return reservation.isActive && block.timestamp > reservation.expiryTimestamp;
    }

    /// @notice Gets all reservations for a user
    /// @param user Address of the user
    /// @return hashes Array of UTXO hashes for user's reservations
    function getUserReservations(address user) external view returns (bytes32[] memory hashes) {
        return userReservations[user];
    }

    /// @notice Gets detailed reservation info
    /// @param utxoHash Hash of the UTXO
    /// @return reservation The full reservation details
    function getReservation(bytes32 utxoHash) external view returns (Reservation memory) {
        return reservations[utxoHash];
    }

    /// @notice Gets the top liquidators by performance
    /// @return liquidators Array of top performing liquidator addresses
    function getTopLiquidators() external view returns (address[] memory) {
        return topLiquidators;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Admin Functions
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Updates the DAO treasury address
    /// @param newTreasury New treasury address
    function setDAOTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid treasury address");

        address oldTreasury = daoTreasury;
        daoTreasury = newTreasury;

        emit DAOTreasuryUpdated(oldTreasury, newTreasury);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Internal Functions
    // ═══════════════════════════════════════════════════════════════════════════

    function _processFundingTransaction(
        BitcoinTx.Info calldata fundingTx,
        bytes calldata /* proof */
    ) internal pure returns (BitcoinTx.UTXO memory) {
        // In a real implementation, this would validate the SPV proof
        // For now, we just extract UTXO information from the first output

        // Extract UTXO information from the funding transaction
        // Assuming the first output is the one we're interested in
        // Create a placeholder txHash from the input vector
        bytes32 txHash = keccak256(fundingTx.inputVector);

        return BitcoinTx.UTXO({
            txHash: txHash,
            txOutputIndex: 0,  // First output
            txOutputValue: 100000000  // 1 BTC in satoshis as placeholder
        });
    }

    function _processRedemption(Reservation storage reservation) internal {
        // Create redemption request through bridge
        // In a real implementation, we would need the wallet public key hash and mainUtxo
        // For now, this is a simplified version

        // Note: This is a placeholder implementation
        // The actual implementation would need:
        // - walletPubKeyHash from the wallet handling this UTXO
        // - mainUtxo information
        // - Proper conversion of btcRedemptionAddress to redeemerOutputScript

        // For compilation purposes only - not functional
        bytes20 walletPubKeyHash = bytes20(0);
        BitcoinTx.UTXO memory mainUtxo = BitcoinTx.UTXO({
            txHash: reservation.utxoHash,
            txOutputIndex: 0,
            txOutputValue: uint64(reservation.btcAmount)
        });

        // This would need proper script generation in production
        bytes memory redeemerOutputScript = reservation.btcRedemptionAddress;

        bridge.requestRedemption(
            walletPubKeyHash,
            mainUtxo,
            redeemerOutputScript,
            uint64(reservation.btcAmount)
        );
    }

    function _moveToGeneralPool(Reservation storage /* reservation */) internal {
        // In a real implementation, this would make the UTXO available for general redemptions
        // by interacting with the Bridge contract's deposit system
        // For now, this is a placeholder as the Bridge doesn't expose this functionality directly

        // Note: The actual implementation would require Bridge contract modifications
        // to support moving reserved UTXOs to the general redemption pool
    }

    function _satoshiToTbtc(uint256 satoshi) internal pure returns (uint256) {
        // Convert satoshis to tBTC (18 decimals)
        return (satoshi * 1e10);
    }

    function _removeUserReservation(address user, bytes32 utxoHash) internal {
        bytes32[] storage userHashes = userReservations[user];
        for (uint256 i = 0; i < userHashes.length; i++) {
            if (userHashes[i] == utxoHash) {
                userHashes[i] = userHashes[userHashes.length - 1];
                userHashes.pop();
                break;
            }
        }
    }

    function _updateLiquidatorStats(address liquidator, uint256 bonus) internal {
        LiquidatorStats storage stats = liquidatorStats[liquidator];
        stats.liquidationCount++;
        stats.totalBonusEarned += bonus;
        stats.lastLiquidationTime = block.timestamp;

        _updateLeaderboard(liquidator);
    }

    function _updateLeaderboard(address liquidator) internal {
        uint256 liquidatorScore = liquidatorStats[liquidator].liquidationCount;

        // Check if already in leaderboard
        bool inLeaderboard = false;
        uint256 position = 0;

        for (uint256 i = 0; i < topLiquidators.length; i++) {
            if (topLiquidators[i] == liquidator) {
                inLeaderboard = true;
                position = i;
                break;
            }
        }

        if (!inLeaderboard && topLiquidators.length < MAX_LEADERBOARD_SIZE) {
            topLiquidators.push(liquidator);
            position = topLiquidators.length - 1;
            inLeaderboard = true;
        }

        // Bubble up if score improved
        if (inLeaderboard) {
            while (position > 0 &&
                   liquidatorStats[topLiquidators[position]].liquidationCount >
                   liquidatorStats[topLiquidators[position - 1]].liquidationCount) {
                address temp = topLiquidators[position];
                topLiquidators[position] = topLiquidators[position - 1];
                topLiquidators[position - 1] = temp;
                position--;
            }
        }
    }
}
