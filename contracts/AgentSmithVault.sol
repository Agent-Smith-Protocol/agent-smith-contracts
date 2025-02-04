// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626, Math} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract AgentSmithVault is ERC20, ERC4626, AccessControl {
    using SafeERC20 for ERC20;
    using Math for uint256;

    enum WithdrawRequestStatus {
        Pending,
        Approved,
        Rejected
    }

    struct WithdrawRequest {
        address owner; /// request owner
        uint256 sharesAmount; /// shares amount for withdrawal
        uint256 timestamp; /// request timestamp
        WithdrawRequestStatus status; /// request status
    }
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE"); /// Access control role for agent
    uint32 public constant PRECISION = 1e6; /// 1e6 precision for fee calculation
    uint32 public constant MAX_FEE = 2e4; /// 2% max fee percentage

    address public agentSmith; /// Agent safe address
    address public treasury; /// Project treasury address
    uint32 public withdrawFee = 1e4; /// 1% default fee for withdrawal

    uint256 public lastUpdate; /// last time price parameters were updated
    uint256 public totalAssetsStored; /// total assets stored in the vault (cross-chain)
    uint256 public totalSharesMinted; /// total shares minted (cross-chain)
    uint256 public withdrawalRequestCounter; /// withdrawal request counter

    mapping(uint256 => WithdrawRequest) public withdrawalRequests; /// withdrawal requests
    mapping(address => bool) public hasWithdrawalRequest; /// user has withdrawal request

    /// @notice reverted when the requested withdrawal amount exceeds the maximum allowed
    error InsufficientBalance();
    /// @notice reverted when caller does not have the required role for action
    error AccessDenied();
    /// @notice reverted when request already exists. Only one pending request per user is allowed
    error AlreadyRequestedWithdraw();
    /// @notice reverted when request not found
    error RequestNotFound();
    /// @notice reverted when request is not pending. Only pending requests can be approved or rejected
    error RequestNotPending();
    /// @notice reverted when Zero address is provided
    error ZeroAddress();
    /// @notice reverted when fee exceeds the maximum allowed. Maximum fee is 2%
    error ExceedsMaxFee();

    /// @notice emitted when a user requests a withdrawal
    event RequestWithdraw(
        address indexed owner,
        uint256 indexed requestId,
        uint256 sharesAmount,
        uint256 timestamp
    );
    /// @notice emitted when a agent approves a withdrawal request
    event WithdrawApproved(uint256 indexed requestId, uint256 feeAmount);
    /// @notice emitted when a withdrawal is rejected
    event WithdrawRejected(uint256 indexed requestId);
    /// @notice emitted when assets delegated to agent
    event DelegateFundsToAgent(uint256 indexed assets);
    /// @notice emitted when a agent address is updated
    event UpdateSmithAddress(address indexed newAgent);
    /// @notice emitted when withdraw fee percentage is updated
    event UpdateWithdrawFeePercent(uint32 newFee);
    /// @notice emitted when price parameters are updated
    event UpdatePriceParameters(
        uint256 newTotalAssetsStored,
        uint256 newTotalSharesMinted
    );
    /// @notice emitted when treasury address were updated
    event UpdateTreasury(address newTreasury);

    /// @notice Create a new AgentSmithVault
    /// @param _name Vault name
    /// @param _symbol Vault symbol
    /// @param _asset Asset address
    /// @param _agentSmith Agent Safe address
    /// @param _treasury Treasury address
    /// @param _defaultAdmin Default admin address
    constructor(
        string memory _name,
        string memory _symbol,
        address _asset,
        address _agentSmith,
        address _treasury,
        address _defaultAdmin
    ) ERC20(_name, _symbol) ERC4626(IERC20(_asset)) {
        agentSmith = _agentSmith;
        treasury = _treasury;
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(AGENT_ROLE, _agentSmith);
    }

    /// @notice Reverts if the caller is not the agent
    modifier onlyAgent() {
        require(hasRole(AGENT_ROLE, _msgSender()), AccessDenied());
        _;
    }

    /// @notice Perform a deposit logic and delegate assets to agent wallet
    /// @param assets Amount of assets to deposit
    /// @param receiver Receiver address
    function deposit(
        uint256 assets,
        address receiver
    ) public override returns (uint256) {
        uint256 maxAssets = maxDeposit(receiver);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        }
        uint256 shares = previewDeposit(assets);
        _deposit(_msgSender(), receiver, assets, shares);

        ERC20 asset = ERC20(asset());
        asset.safeTransfer(agentSmith, assets);
        emit DelegateFundsToAgent(assets);

        return shares;
    }

    /// @notice Perform a withdrawal request logic
    /// @param assets Amount of assets to withdraw
    /// @param owner Owner address
    function requestWithdraw(uint256 assets, address owner) external {
        require(_msgSender() == owner, AccessDenied());
        require(!hasWithdrawalRequest[owner], AlreadyRequestedWithdraw());
        uint256 maxAssets = maxWithdraw(owner);
        if (assets > maxAssets) {
            revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        }
        uint256 shares = previewWithdraw(assets);
        withdrawalRequestCounter++;
        withdrawalRequests[withdrawalRequestCounter] = WithdrawRequest(
            owner,
            shares,
            block.timestamp,
            WithdrawRequestStatus.Pending
        );
        emit RequestWithdraw(
            owner,
            withdrawalRequestCounter,
            shares,
            block.timestamp
        );
    }

    /// @notice Perform a withdrawal approval logic. Only agent can approve withdrawal
    /// @param requestId Withdrawal request id
    function approveWithdraw(uint256 requestId) external onlyAgent {
        WithdrawRequest memory request = withdrawalRequests[requestId];
        require(
            request.status == WithdrawRequestStatus.Pending,
            RequestNotPending()
        );
        withdrawalRequests[requestId].status = WithdrawRequestStatus.Approved;
        hasWithdrawalRequest[request.owner] = false;
        ERC20 asset = ERC20(asset());
        uint256 assets = previewWithdraw(request.sharesAmount);
        require(
            assets <= IERC20(asset).balanceOf(address(this)),
            InsufficientBalance()
        );
        uint256 fee = _calcWithdrawFee(assets);
        uint256 netAssets = assets - fee;

        _burn(request.owner, request.sharesAmount);
        ERC20(asset).safeTransfer(request.owner, netAssets);
        ERC20(asset).safeTransfer(treasury, fee);

        emit WithdrawApproved(requestId, fee);
        emit Withdraw(
            _msgSender(),
            request.owner,
            request.owner,
            assets,
            request.sharesAmount
        );
    }

    /// @notice Perform a withdrawal rejection logic. Only agent can reject withdrawal
    /// @param requestId Withdrawal request id
    function rejectWithdraw(uint256 requestId) external onlyAgent {
        WithdrawRequest memory request = withdrawalRequests[requestId];
        require(
            request.status == WithdrawRequestStatus.Pending,
            RequestNotPending()
        );
        withdrawalRequests[requestId].status = WithdrawRequestStatus.Rejected;
        hasWithdrawalRequest[request.owner] = false;
        emit WithdrawRejected(requestId);
    }

    /// @notice Delegate all assets to agent wallet for providing liquidity to strategies
    function delegateFundsToAgent() external onlyAgent {
        ERC20 asset = ERC20(asset());
        uint256 assetBalance = asset.balanceOf(address(this));
        require(assetBalance > 0, InsufficientBalance());
        asset.safeTransfer(agentSmith, assetBalance);
        emit DelegateFundsToAgent(assetBalance);
    }

    /// @notice Update agent address
    function updateSmithAddress(
        address newAgent
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newAgent != address(0), ZeroAddress());
        agentSmith = newAgent;
        emit UpdateSmithAddress(newAgent);
    }

    /// @notice Update withdraw fee percentage
    /// @param newFee New fee percentage
    function updateWithdrawFeePercent(
        uint32 newFee
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFee <= MAX_FEE, ExceedsMaxFee());
        withdrawFee = newFee;
        emit UpdateWithdrawFeePercent(newFee);
    }

    /// @notice Update price parameters. Can be called by agent
    /// @param newTotalAssetsStored New total assets stored (cross-chain)
    /// @param newTotalSharesMinted New total shares minted (cross-chain)
    function updatePriceParameters(
        uint256 newTotalAssetsStored,
        uint256 newTotalSharesMinted
    ) external onlyRole(AGENT_ROLE) {
        totalAssetsStored = newTotalAssetsStored;
        totalSharesMinted = newTotalSharesMinted;
        lastUpdate = block.timestamp;
        emit UpdatePriceParameters(newTotalAssetsStored, newTotalSharesMinted);
    }

    function updateTreasury(
        address newTreasury
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), ZeroAddress());
        treasury = newTreasury;
        emit UpdateTreasury(newTreasury);
    }

    function redeem(
        uint256 shares,
        address receiver,
        address owner
    ) public override returns (uint256) {}

    function mint(
        uint256 shares,
        address receiver
    ) public override returns (uint256) {}

    function totalAssets() public view override returns (uint256) {
        return totalAssetsStored;
    }

    function crossChainTotalSupply() public view returns (uint256) {
        return totalSharesMinted;
    }

    function decimals()
        public
        view
        virtual
        override(ERC20, ERC4626)
        returns (uint8)
    {
        return ERC20(asset()).decimals();
    }

    function _calcWithdrawFee(uint256 assets) internal view returns (uint256) {
        return (assets * withdrawFee) / PRECISION;
    }

    function _convertToShares(
        uint256 assets,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        return
            assets.mulDiv(
                crossChainTotalSupply() + 10 ** _decimalsOffset(),
                totalAssets() + 1,
                rounding
            );
    }

    function _convertToAssets(
        uint256 shares,
        Math.Rounding rounding
    ) internal view override returns (uint256) {
        return
            shares.mulDiv(
                totalAssets() + 1,
                crossChainTotalSupply() + 10 ** _decimalsOffset(),
                rounding
            );
    }
}
