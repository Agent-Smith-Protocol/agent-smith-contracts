import { expect } from "chai";
import { ethers } from "hardhat";
import { Wallet } from "ethers";
import {
  AgentSmithVault,
  AgentSmithVault__factory,
  TestToken,
} from "../typechain-types";
import { SignerWithAddress } from "@nomiclabs/hardhat-ethers/signers";

describe("Vault tests", function () {
  let vault: AgentSmithVault;
  let vaultFactory: AgentSmithVault__factory;
  let owner: SignerWithAddress;
  let agent: SignerWithAddress;
  let treasury: SignerWithAddress;
  let accounts: SignerWithAddress[];
  let usdc: TestToken;
  before(async () => {
    const [acc1, acc2, acc3, ...others] = await ethers.getSigners();
    owner = acc1;
    agent = acc2;
    treasury = acc3;
    accounts = others;

    const TestTokenFactory = await ethers.getContractFactory("TestToken");
    usdc = await TestTokenFactory.deploy(
      "USDC",
      "USDC",
      6,
      ethers.utils.parseEther("1000000")
    );
    await usdc.deployed();

    vaultFactory = await ethers.getContractFactory("AgentSmithVault");
    vault = await vaultFactory.deploy(
      "test vault",
      "TV",
      usdc.address,
      agent.address,
      treasury.address,
      owner.address
    );
    await vault.deployed();
  });

  describe("Vault logic", async () => {
    it("Make initial deposit", async () => {
      const depositAmount = await ethers.utils.parseUnits("1", 6);
      await usdc.approve(vault.address, depositAmount);
      await vault.deposit(depositAmount, owner.address);
      const balance = await vault.balanceOf(owner.address);
      expect(balance).to.eq(depositAmount);
      const totalSupply = await vault.totalSupply();
      expect(totalSupply).to.eq(depositAmount);
      const sharesPrice = await vault.convertToAssets(depositAmount);
      expect(sharesPrice).to.eq(depositAmount);
    });

    it("Request withdrawal", async () => {
      const requestId = (await vault.withdrawalRequestCounter()).add(1);
      const withdrawAmount = await ethers.utils.parseUnits("1", 6);
      await vault.requestWithdraw(withdrawAmount, owner.address);
      const withdrawalRequest = await vault.withdrawalRequests(requestId);
      expect(withdrawalRequest.sharesAmount).to.eq(withdrawAmount);
      expect(withdrawalRequest.owner).to.eq(owner.address);
      expect(withdrawalRequest.status).to.eq(0);
    });

    it("Approve withdrawal", async () => {
      const requestId = await vault.withdrawalRequestCounter();
      const withdrawalRequestBefore = await vault.withdrawalRequests(requestId);
      const requesterBalanceBefore = await usdc.balanceOf(
        withdrawalRequestBefore.owner
      );
      const treasuryBalanceBefore = await usdc.balanceOf(treasury.address);
      await usdc
        .connect(agent)
        .transfer(vault.address, withdrawalRequestBefore.sharesAmount);
      await vault.connect(agent).approveWithdraw(requestId);
      const requesterBalanceAfter = await usdc.balanceOf(
        withdrawalRequestBefore.owner
      );
      const treasuryBalanceAfter = await usdc.balanceOf(treasury.address);

      const feePercent = await vault.withdrawFee();
      const precission = await vault.PRECISION();
      const fee = withdrawalRequestBefore.sharesAmount
        .mul(feePercent)
        .div(precission);

      expect(requesterBalanceAfter).to.eq(
        requesterBalanceBefore.add(
          withdrawalRequestBefore.sharesAmount.sub(fee)
        )
      );
      expect(treasuryBalanceAfter).to.eq(treasuryBalanceBefore.add(fee));

      const withdrawalRequestAfter = await vault.withdrawalRequests(requestId);
      expect(withdrawalRequestAfter.status).to.eq(1);
    });
    it("Reject withdrawal", async () => {
      const depositAmount = await ethers.utils.parseUnits("1", 6);
      await usdc.approve(vault.address, depositAmount);
      await vault.deposit(depositAmount, owner.address);
      const requestId = (await vault.withdrawalRequestCounter()).add(1);
      const withdrawAmount = await ethers.utils.parseUnits("1", 6);
      await vault.requestWithdraw(withdrawAmount, owner.address);

      await vault.connect(agent).rejectWithdraw(requestId);
      const withdrawalRequestAfter = await vault.withdrawalRequests(requestId);
      expect(withdrawalRequestAfter.status).to.eq(2);
    });
  });
  describe("Cross-chain logic", async () => {
    it("Should chage totalAssets and totalSupply", async () => {
      const depositAmount = await ethers.utils.parseUnits("1", 6);
      await usdc.approve(vault.address, depositAmount);
      await vault.deposit(depositAmount, owner.address);
      await vault
        .connect(agent)
        .updatePriceParameters(
          ethers.utils.parseUnits("10", 6),
          ethers.utils.parseUnits("5", 6)
        );

      const newSharesPrice = await vault.convertToAssets(depositAmount);
      console.log(
        "newSharesPrice",
        ethers.utils.formatUnits(newSharesPrice, 6)
      );
      expect(newSharesPrice).to.be.gt(depositAmount);
    });
  });
});
