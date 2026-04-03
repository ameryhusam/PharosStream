// SPDX-License-Identifier: MIT
pragma solidity ^0.8.34;

// Correct raw.githubusercontent.com imports for OpenZeppelin v5.0.3
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.3/contracts/utils/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.3/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.3/contracts/utils/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.3/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.3/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PharosStreamPro v2.1 - Native PHRS Version
 * @notice Real-time payment streaming escrow for Pharos Atlantic Testnet using native PHRS.
 * Owner: 0xB656F85852F37317a5d9F60E74170b8d336510E1
 */
contract PharosStreamPro is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    address public treasury;
    uint256 public platformFeePercent = 5; // 5% default
    uint256 public nextServiceId = 1;
    uint256 public nextStreamId = 1;

    IERC20 public paymentToken; // address(0) = native PHRS

    struct Service {
        string label;
        uint256 cost;
        uint256 duration; 
        bool active;
    }

    struct Stream {
        uint256 serviceId;
        address payer;
        address recipient;
        uint256 startTime;
        uint256 durationAtBooking;
        uint256 totalEscrow;
        uint256 claimed;
        string jobURI;
        bool closed;
        bool disputed;
    }

    mapping(uint256 => Service) public registry;
    mapping(uint256 => Stream) public streams;

    event ServiceCreated(uint256 indexed id, string label, uint256 price);
    event PaymentStarted(uint256 indexed streamId, address indexed client, address indexed tech, string jobURI);
    event Withdraw(uint256 indexed streamId, uint256 amount);
    event StreamResolved(uint256 indexed streamId, uint256 providerPay, uint256 clientRefund);
    event StreamExtended(uint256 indexed streamId, uint256 addedTime);
    event StreamDisputed(uint256 indexed streamId, address disputer);
    event StreamCancelled(uint256 indexed streamId, uint256 providerPay, uint256 clientRefund);

    constructor(address _initialTreasury, address _paymentToken) 
        Ownable(0xB656F85852F37317a5d9F60E74170b8d336510E1)
    {
        require(_initialTreasury != address(0), "Treasury cannot be zero");
        treasury = _initialTreasury;
        paymentToken = IERC20(_paymentToken);
    }

    modifier auth() {
        require(msg.sender == owner(), "Access: Admin only");
        _;
    }

    // ====================== ADMIN FUNCTIONS ======================
    function listService(string calldata _label, uint256 _cost, uint256 _sec) external auth whenNotPaused {
        require(_cost > 0 && _sec > 0, "Invalid service params");
        registry[nextServiceId] = Service(_label, _cost, _sec, true);
        emit ServiceCreated(nextServiceId, _label, _cost);
        nextServiceId++;
    }

    function toggleService(uint256 _sid) external auth {
        registry[_sid].active = !registry[_sid].active;
    }

    function setPlatformFee(uint256 _newFeePercent) external auth {
        require(_newFeePercent <= 10, "Fee too high");
        platformFeePercent = _newFeePercent;
    }

    function setTreasury(address _newTreasury) external auth {
        require(_newTreasury != address(0), "Zero address");
        treasury = _newTreasury;
    }

    function pause() external auth { _pause(); }
    function unpause() external auth { _unpause(); }

    function resolveStream(uint256 _id, uint256 _providerPay) external auth whenNotPaused {
        Stream storage st = streams[_id];
        require(!st.closed, "Stream: Already settled");

        uint256 remaining = st.totalEscrow - st.claimed;
        require(_providerPay <= remaining, "Invalid split");

        uint256 refund = remaining - _providerPay;
        st.closed = true;

        _transferTo(st.recipient, _providerPay);
        _transferTo(st.payer, refund);

        st.claimed += _providerPay;
        emit StreamResolved(_id, _providerPay, refund);
    }

    // ====================== USER FUNCTIONS ======================
    function bookJob(uint256 _sid, address _worker, string calldata _jobURI) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        Service storage s = registry[_sid];
        require(s.active, "Registry: Service disabled");
        require(_worker != address(0), "Invalid worker");

        uint256 fee = (s.cost * platformFeePercent) / 100;
        uint256 netAmount = s.cost - fee;

        if (address(paymentToken) == address(0)) {
            require(msg.value == s.cost, "Incorrect PHRS amount");
            _transferTo(treasury, fee);
        } else {
            require(msg.value == 0, "Use ERC20 only");
            paymentToken.safeTransferFrom(msg.sender, address(this), s.cost);
            paymentToken.safeTransfer(treasury, fee);
        }

        streams[nextStreamId] = Stream({
            serviceId: _sid,
            payer: msg.sender,
            recipient: _worker,
            startTime: block.timestamp,
            durationAtBooking: s.duration,
            totalEscrow: netAmount,
            claimed: 0,
            jobURI: _jobURI,
            closed: false,
            disputed: false
        });

        emit PaymentStarted(nextStreamId, msg.sender, _worker, _jobURI);
        nextStreamId++;
    }

    function extendStream(uint256 _id, uint256 _additionalSeconds) external whenNotPaused {
        Stream storage st = streams[_id];
        require(msg.sender == st.payer, "Only client can extend");
        require(!st.closed && !st.disputed, "Stream not active");

        st.durationAtBooking += _additionalSeconds;
        emit StreamExtended(_id, _additionalSeconds);
    }

    function disputeStream(uint256 _id) external whenNotPaused {
        Stream storage st = streams[_id];
        require(!st.closed, "Already closed");
        require(msg.sender == st.payer || msg.sender == st.recipient, "Only parties");

        st.disputed = true;
        emit StreamDisputed(_id, msg.sender);
    }

    function cancelStream(uint256 _id) external whenNotPaused {
        Stream storage st = streams[_id];
        require(!st.closed && !st.disputed, "Stream not active");
        require(msg.sender == st.payer || msg.sender == st.recipient, "Only parties");

        uint256 timePassed = block.timestamp - st.startTime;
        uint256 earned = (timePassed >= st.durationAtBooking) 
            ? st.totalEscrow - st.claimed 
            : (st.totalEscrow * timePassed) / st.durationAtBooking;

        uint256 refund = (st.totalEscrow - st.claimed) - earned;

        st.closed = true;

        _transferTo(st.recipient, earned);
        _transferTo(st.payer, refund);

        st.claimed += earned;
        emit StreamCancelled(_id, earned, refund);
    }

    function checkAvailable(uint256 _id) public view returns (uint256) {
        Stream storage st = streams[_id];
        if (st.closed || st.disputed) return 0;

        if (block.timestamp >= st.startTime + st.durationAtBooking) {
            return st.totalEscrow - st.claimed;
        }

        uint256 timePassed = block.timestamp - st.startTime;
        uint256 earned = (st.totalEscrow * timePassed) / st.durationAtBooking;
        if (earned <= st.claimed) return 0;
        return earned - st.claimed;
    }

    function collectPay(uint256 _id) external nonReentrant whenNotPaused {
        Stream storage st = streams[_id];
        require(msg.sender == st.recipient, "Only recipient");

        uint256 payout = checkAvailable(_id);
        require(payout > 0, "No funds available");

        st.claimed += payout;
        if (st.claimed >= st.totalEscrow) st.closed = true;

        _transferTo(msg.sender, payout);
        emit Withdraw(_id, payout);
    }

    function batchCollectPay(uint256[] calldata _streamIds) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(_streamIds.length > 0 && _streamIds.length <= 50, "Batch limit: 1-50 streams");

        uint256 totalPayout = 0;

        for (uint256 i = 0; i < _streamIds.length; i++) {
            uint256 _id = _streamIds[i];
            Stream storage st = streams[_id];

            if (msg.sender != st.recipient || st.closed || st.disputed) continue;

            uint256 payout = checkAvailable(_id);
            if (payout == 0) continue;

            st.claimed += payout;
            if (st.claimed >= st.totalEscrow) st.closed = true;

            totalPayout += payout;
            emit Withdraw(_id, payout);
        }

        require(totalPayout > 0, "Batch: No funds available");
        _transferTo(msg.sender, totalPayout);
    }

    function _transferTo(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (address(paymentToken) == address(0)) {
            (bool success, ) = payable(to).call{value: amount}("");
            require(success, "Native PHRS transfer failed");
        } else {
            paymentToken.safeTransfer(to, amount);
        }
    }

    receive() external payable {}
}