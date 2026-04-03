// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/access/Ownable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/utils/Pausable.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/token/ERC20/IERC20.sol";
import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PharosStreamPro v2.2 - Hardcoded Initialization
 * @notice Ready for one-click deployment on Pharos Atlantic.
 */
contract PharosStreamPro is ReentrancyGuard, Ownable, Pausable {
    using SafeERC20 for IERC20;

    // --- HARDCODED SETTINGS ---
    address public constant TREASURY = 0xB656F85852F37317a5d9F60E74170b8d336510E1;
    address public constant INITIAL_OWNER = 0xB656F85852F37317a5d9F60E74170b8d336510E1;
    address public constant NATIVE_TOKEN = address(0); 

    uint256 public platformFeePercent = 5; 
    uint256 public nextServiceId = 1;
    uint256 public nextStreamId = 1;

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

    // FIXED: Constructor now ignores inputs and uses hardcoded addresses
    constructor() Ownable(INITIAL_OWNER) {
        // Treasury is set via the constant above
    }

    modifier auth() {
        require(msg.sender == owner(), "Access: Admin only");
        _;
    }

    // ====================== ADMIN FUNCTIONS ======================

    function listService(string calldata _label, uint256 _cost, uint256 _sec) external auth whenNotPaused {
        require(_cost > 0 && _sec > 0, "Invalid params");
        registry[nextServiceId] = Service(_label, _cost, _sec, true);
        emit ServiceCreated(nextServiceId, _label, _cost);
        nextServiceId++;
    }

    // ====================== USER FUNCTIONS ======================

    function bookJob(uint256 _sid, address _worker, string calldata _jobURI) 
        external 
        payable 
        nonReentrant 
        whenNotPaused 
    {
        Service storage s = registry[_sid];
        require(s.active, "Service disabled");
        
        uint256 fee = (s.cost * platformFeePercent) / 100;
        uint256 netAmount = s.cost - fee;

        // Using Native PHRS logic
        require(msg.value == s.cost, "Incorrect PHRS amount");
        
        // Transfer fee to hardcoded treasury
        (bool feeSuccess, ) = payable(TREASURY).call{value: fee}("");
        require(feeSuccess, "Fee transfer failed");

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
        require(payout > 0, "No funds");

        st.claimed += payout;
        if (st.claimed >= st.totalEscrow) st.closed = true;

        (bool success, ) = payable(msg.sender).call{value: payout}("");
        require(success, "Transfer failed");
        
        emit Withdraw(_id, payout);
    }

    receive() external payable {}
}
