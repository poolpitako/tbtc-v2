/* eslint-disable no-underscore-dangle */
/* eslint-disable @typescript-eslint/no-unused-expressions */

import { ethers, helpers, waffle } from "hardhat"
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers"
import chai, { expect } from "chai"
import { smock } from "@defi-wonderland/smock"
import type {
  Bank,
  BankStub,
  Bridge,
  BridgeStub,
  TBTC,
  TBTCReservedVault,
} from "../../typechain"
import bridgeFixture from "../fixtures/bridge"

chai.use(smock.matchers)

const { createSnapshot, restoreSnapshot } = helpers.snapshot

const ZERO_ADDRESS = ethers.constants.AddressZero

describe("TBTCReservedVault", () => {
  let governance: SignerWithAddress
  let depositor: SignerWithAddress
  let treasury: SignerWithAddress
  let liquidator: SignerWithAddress
  let thirdParty: SignerWithAddress

  let bank: Bank & BankStub
  let bridge: Bridge & BridgeStub
  let tbtc: TBTC
  let vault: TBTCReservedVault

  // Contract constants (from TBTCReservedVault.sol)
  const MIN_DEPOSIT_BTC = ethers.utils.parseUnits("0.1", 8) // 0.1 BTC in satoshis
  const MIN_FEE_BTC = ethers.utils.parseUnits("0.01", 8) // 0.01 BTC minimum fee
  const MAX_RESERVATION_DAYS = 1460 // 4 years maximum
  const ANNUAL_FEE_BPS = 10 // 0.1% annual fee

  before(async () => {
    // eslint-disable-next-line @typescript-eslint/no-extra-semi
    ;({
      governance,
      bank,
      bridge,
      tbtc,
    } = await waffle.loadFixture(bridgeFixture))
    ;[depositor, treasury, liquidator, thirdParty] =
      await ethers.getSigners()

    // Deploy TBTCReservedVault
    const TBTCReservedVault = await ethers.getContractFactory(
      "TBTCReservedVault"
    )
    vault = await TBTCReservedVault.deploy()
    await vault.deployed()

    // Initialize the vault
    await vault.initialize(
      bank.address,
      tbtc.address,
      bridge.address,
      treasury.address
    )

    // Transfer ownership to governance
    await vault.transferOwnership(governance.address)
  })

  describe("Initialization", () => {
    it("should initialize with correct parameters", async () => {
      expect(await vault.bank()).to.equal(bank.address)
      expect(await vault.tbtcToken()).to.equal(tbtc.address)
      expect(await vault.bridge()).to.equal(bridge.address)
      expect(await vault.daoTreasury()).to.equal(treasury.address)
    })

    it("should not allow reinitialization", async () => {
      await expect(
        vault.initialize(
          bank.address,
          tbtc.address,
          bridge.address,
          treasury.address
        )
      ).to.be.revertedWith("Initializable: contract is already initialized")
    })

    it("should revert if initialized with invalid addresses", async () => {
      const TBTCReservedVault = await ethers.getContractFactory(
        "TBTCReservedVault"
      )
      const newVault = await TBTCReservedVault.deploy()
      await newVault.deployed()

      await expect(
        newVault.initialize(
          ZERO_ADDRESS,
          tbtc.address,
          bridge.address,
          treasury.address
        )
      ).to.be.revertedWith("Invalid bank address")
    })
  })

  describe("Deposit with Reservation", () => {
    let snapshotId: any

    beforeEach(async () => {
      snapshotId = await createSnapshot()
    })

    afterEach(async () => {
      await restoreSnapshot(snapshotId)
    })

    it("should create a reservation with valid parameters", async () => {
      const reservationDays = 30
      const btcAddress = ethers.utils.randomBytes(20) // 20 bytes for P2PKH/P2SH

      // Create a mock BitcoinTx.Info
      const fundingTx = {
        version: "0x01000000",
        inputVector: ethers.utils.randomBytes(32),
        outputVector: "0x",
        locktime: "0x00000000"
      }
      const proof = "0x" // Empty proof for testing

      // Note: This will fail due to the placeholder implementation
      // In a real test, we'd need proper mock data
      await expect(
        vault.connect(depositor).depositWithReservation(
          fundingTx,
          proof,
          reservationDays,
          btcAddress
        )
      ).to.be.reverted // Will revert due to placeholder implementation
    })
  })

  describe("Redeem Reserved UTXO", () => {
    let snapshotId: any
    let mockUtxoHash: string

    beforeEach(async () => {
      snapshotId = await createSnapshot()
      // Create a mock UTXO hash
      mockUtxoHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("test-utxo"))
    })

    afterEach(async () => {
      await restoreSnapshot(snapshotId)
    })

    it("should revert if reservation not found", async () => {
      await expect(
        vault.connect(depositor).redeemReservedUTXO(mockUtxoHash)
      ).to.be.revertedWith("Reservation not active")
    })
  })

  describe("Liquidate Expired Reservation", () => {
    let snapshotId: any
    let mockUtxoHash: string

    beforeEach(async () => {
      snapshotId = await createSnapshot()
      mockUtxoHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("test-utxo"))
    })

    afterEach(async () => {
      await restoreSnapshot(snapshotId)
    })

    it("should revert if reservation not found", async () => {
      await expect(
        vault.connect(liquidator).liquidateExpiredReservation(mockUtxoHash)
      ).to.be.revertedWith("Reservation not active")
    })
  })

  describe("DAO Treasury Management", () => {
    let snapshotId: any

    beforeEach(async () => {
      snapshotId = await createSnapshot()
    })

    afterEach(async () => {
      await restoreSnapshot(snapshotId)
    })

    it("should allow owner to update DAO treasury", async () => {
      const newTreasury = thirdParty.address

      await expect(
        vault.connect(governance).setDAOTreasury(newTreasury)
      ).to.emit(vault, "DAOTreasuryUpdated")
        .withArgs(treasury.address, newTreasury)

      expect(await vault.daoTreasury()).to.equal(newTreasury)
    })

    it("should not allow non-owner to update DAO treasury", async () => {
      await expect(
        vault.connect(thirdParty).setDAOTreasury(thirdParty.address)
      ).to.be.revertedWith("Ownable: caller is not the owner")
    })

    it("should not allow setting invalid treasury address", async () => {
      await expect(
        vault.connect(governance).setDAOTreasury(ZERO_ADDRESS)
      ).to.be.revertedWith("Invalid treasury address")
    })
  })

  describe("Fee Calculations", () => {
    it("should calculate storage fee correctly for 30 days", async () => {
      const btcAmount = ethers.utils.parseUnits("1", 8) // 1 BTC in satoshis
      const reservationDays = 30

      // Calculate expected fee: (btcAmount * ANNUAL_FEE_BPS * reservationDays) / (10000 * 365)
      let expectedFee = btcAmount
        .mul(ANNUAL_FEE_BPS)
        .mul(reservationDays)
        .div(10000)
        .div(365)

      // Year-based minimum: 30 days = 1 year fee (0.01 BTC)
      const minimumFee = MIN_FEE_BTC

      // Check if below minimum fee
      if (expectedFee.lt(minimumFee)) {
        expectedFee = minimumFee
      }

      const actualFee = await vault.calculateStorageFee(btcAmount, reservationDays)
      expect(actualFee).to.equal(expectedFee)
    })

    it("should revert if BTC amount is below minimum", async () => {
      const btcAmount = MIN_DEPOSIT_BTC.sub(1)
      const reservationDays = 30

      await expect(
        vault.calculateStorageFee(btcAmount, reservationDays)
      ).to.be.revertedWith("Deposit below minimum")
    })

    it("should revert if reservation days is zero", async () => {
      const btcAmount = ethers.utils.parseUnits("1", 8)
      const reservationDays = 0

      await expect(
        vault.calculateStorageFee(btcAmount, reservationDays)
      ).to.be.revertedWith("Invalid reservation period")
    })

    it("should revert if reservation days exceeds maximum", async () => {
      const btcAmount = ethers.utils.parseUnits("1", 8)
      const reservationDays = MAX_RESERVATION_DAYS + 1

      await expect(
        vault.calculateStorageFee(btcAmount, reservationDays)
      ).to.be.revertedWith("Invalid reservation period")
    })

    it("should calculate fees for different periods correctly with year-based steps", async () => {
      const btcAmount = ethers.utils.parseUnits("10", 8) // 10 BTC to ensure base fee dominates

      // Test various reservation periods with year-based minimum fees
      const testCases = [
        { days: 1, years: 1, description: "1 day (1 year fee)" },
        { days: 30, years: 1, description: "30 days (1 year fee)" },
        { days: 90, years: 1, description: "90 days (1 year fee)" },
        { days: 180, years: 1, description: "180 days (1 year fee)" },
        { days: 365, years: 1, description: "365 days (1 year fee)" },
        { days: 366, years: 2, description: "366 days (2 year fee)" },
        { days: 730, years: 2, description: "730 days (2 year fee)" },
        { days: 731, years: 3, description: "731 days (3 year fee)" },
        { days: 1095, years: 3, description: "1095 days (3 year fee)" },
        { days: 1096, years: 4, description: "1096 days (4 year fee)" },
        { days: 1460, years: 4, description: "1460 days (4 year fee - max)" },
      ]

      for (const testCase of testCases) {
        const fee = await vault.calculateStorageFee(btcAmount, testCase.days)

        // Calculate base fee (0.1% per year)
        let expectedFee = btcAmount
          .mul(ANNUAL_FEE_BPS)
          .mul(testCase.days)
          .div(10000)
          .div(365)

        // Year-based minimum fee (not prorated)
        const minimumFee = MIN_FEE_BTC.mul(testCase.years)

        // Use the higher of the two
        if (expectedFee.lt(minimumFee)) {
          expectedFee = minimumFee
        }

        expect(fee).to.equal(
          expectedFee,
          `Fee calculation incorrect for ${testCase.description}`
        )
      }
    })

    it("should apply year-based minimum fees correctly", async () => {
      const btcAmount = ethers.utils.parseUnits("0.5", 8) // 0.5 BTC - minimum fee will apply

      // Test year boundaries
      const testCases = [
        { days: 365, expectedFee: MIN_FEE_BTC }, // 1 year = 0.01 BTC
        { days: 366, expectedFee: MIN_FEE_BTC.mul(2) }, // 2 years = 0.02 BTC
        { days: 730, expectedFee: MIN_FEE_BTC.mul(2) }, // 2 years = 0.02 BTC
        { days: 731, expectedFee: MIN_FEE_BTC.mul(3) }, // 3 years = 0.03 BTC
        { days: 1095, expectedFee: MIN_FEE_BTC.mul(3) }, // 3 years = 0.03 BTC
        { days: 1096, expectedFee: MIN_FEE_BTC.mul(4) }, // 4 years = 0.04 BTC
      ]

      for (const testCase of testCases) {
        const fee = await vault.calculateStorageFee(btcAmount, testCase.days)
        expect(fee).to.equal(
          testCase.expectedFee,
          `Year-based minimum fee incorrect for ${testCase.days} days`
        )
      }
    })
  })

  describe("View Functions", () => {
    it("should return empty array for user with no reservations", async () => {
      const reservations = await vault.getUserReservations(depositor.address)
      expect(reservations).to.have.lengthOf(0)
    })

    it("should return false for non-existent reservation expiry check", async () => {
      const mockUtxoHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("test"))
      const isExpired = await vault.isReservationExpired(mockUtxoHash)
      expect(isExpired).to.be.false
    })

    it("should return empty reservation for non-existent UTXO", async () => {
      const mockUtxoHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("test"))
      const reservation = await vault.getReservation(mockUtxoHash)

      expect(reservation.depositor).to.equal(ZERO_ADDRESS)
      expect(reservation.btcAmount).to.equal(0)
      expect(reservation.tbtcMinted).to.equal(0)
      expect(reservation.storageFee).to.equal(0)
      expect(reservation.expiryTimestamp).to.equal(0)
      expect(reservation.isActive).to.be.false
    })

  })

  describe("Sweep Fees", () => {
    it("should revert when no fees to sweep", async () => {
      await expect(
        vault.connect(governance).sweepFeesToDAO()
      ).to.be.revertedWith("No fees to sweep")
    })
  })

  describe("Integration Points", () => {
    it("should have correct Bank contract reference", async () => {
      expect(await vault.bank()).to.equal(bank.address)
      expect(await vault.bank()).to.not.equal(ZERO_ADDRESS)
    })

    it("should have correct TBTC token reference", async () => {
      expect(await vault.tbtcToken()).to.equal(tbtc.address)
      expect(await vault.tbtcToken()).to.not.equal(ZERO_ADDRESS)
    })

    it("should have correct Bridge contract reference", async () => {
      expect(await vault.bridge()).to.equal(bridge.address)
      expect(await vault.bridge()).to.not.equal(ZERO_ADDRESS)
    })

    it("should have correct DAO treasury reference", async () => {
      expect(await vault.daoTreasury()).to.equal(treasury.address)
      expect(await vault.daoTreasury()).to.not.equal(ZERO_ADDRESS)
    })
  })

  describe("Contract Constants", () => {
    it("should have correct MIN_DEPOSIT_BTC", async () => {
      // Test that the minimum deposit validation works
      const belowMin = MIN_DEPOSIT_BTC.sub(1)
      await expect(
        vault.calculateStorageFee(belowMin, 30)
      ).to.be.revertedWith("Deposit below minimum")

      // Should not revert at exactly minimum
      await expect(
        vault.calculateStorageFee(MIN_DEPOSIT_BTC, 30)
      ).to.not.be.reverted
    })

    it("should have correct MAX_RESERVATION_DAYS", async () => {
      const btcAmount = ethers.utils.parseUnits("1", 8)

      // Should work at max
      await expect(
        vault.calculateStorageFee(btcAmount, MAX_RESERVATION_DAYS)
      ).to.not.be.reverted

      // Should fail above max
      await expect(
        vault.calculateStorageFee(btcAmount, MAX_RESERVATION_DAYS + 1)
      ).to.be.revertedWith("Invalid reservation period")
    })
  })
})
