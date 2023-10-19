// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.20;

/// @title A lending order book for ERC20 tokens
/// @author Pré-vert
/// @notice Allows users to place limit orders on the book, take orders, and borrow assets
/// @dev A money market for the pair base/quote is handled by a single contract
/// which manages both order book operations lending/borrowing operations

//import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IOrderBook} from "./interfaces/IOrderBook.sol";
import {console} from "forge-std/Test.sol";

contract OrderBook is IOrderBook {

    IERC20 public quoteToken;
    IERC20 public baseToken;

    /// @notice provide core public functions (deposit, increase deposit, withdraw, take, borrow, repay),
    /// internal functions (liquidate) and view functions

    uint256 constant MAX_POSITIONS = 5; // How many positions can be borrowed from a single order
    uint256 constant MAX_ORDERS = 10; // How many buy and sell orders can be placed by a single address
    uint256 constant MAX_BORROWINGS = 5; // How many positions a borrower can open both sides of the book
    uint256 constant MIN_DEPOSIT_BASE = 1; // Minimum deposited base tokens to be received by takers
    uint256 constant MIN_DEPOSIT_QUOTE = 100; // Minimum deposited base tokens to be received by takers
    uint256 constant ABSENT = type(uint256).max; // id for non existing order or position in arrays
    
    struct Order {
        address maker; // address of the maker
        bool isBuyOrder; // true for buy orders, false for sell orders
        uint256 quantity; // assets deposited (quoteToken for buy orders, baseToken for sell orders)
        uint256 price; // price of the order
        uint256[MAX_POSITIONS] positionIds; // stores positions id in mapping positions who borrow from order
    }

    // makers and borrowers
    struct User {
        uint256[MAX_ORDERS] depositIds; // stores orders id in mapping orders in which borrower deposits
        uint256[MAX_BORROWINGS] borrowFromIds; // stores orders id in mapping orders from which borrower borrows
    }

    // borrowing positions
    struct Position {
        address borrower; // address of the borrower
        uint256 orderId; // stores orders id in mapping orders, from which assets are borrowed
        uint256 borrowedAssets; // quantity of assets borrowed (quoteToken for buy orders, baseToken for sell orders)
    }

    mapping(uint256 orderId => Order) public orders;
    mapping(address user => User) public users;
    mapping(uint256 positionId => Position) public positions;

    uint256 lastOrderId; // id of the last order in orders
    uint256 lastPositionId; // id of the last position in positions

    constructor(address _quoteToken, address _baseToken) {
        quoteToken = IERC20(_quoteToken);
        baseToken = IERC20(_baseToken);
        lastOrderId = 1; // id of the last order in orders (0 is kept for non existing orders)
        lastPositionId = 1; // id of the last position in positions (0 is kept for non existing positions)
    }

    modifier orderExists(uint256 _orderId) {
        _revertIfOrderDoesntExist(_orderId);
        _;
    }

    modifier positionExists(uint256 _positionId) {
        _RevertIfPositionDoesntExist(_positionId);
        _;
    }

    modifier isPositive(uint256 _var) {
        _checkPositive(_var);
        _;
    }

    modifier onlyMaker(address maker) {
        _onlyMaker(maker);
        _;
    }

    /// @notice lets users place orders in the order book
    /// @dev Update ERC20 balances
    /// @param _quantity The quantity of assets deposited (quoteToken for buy orders, baseToken for sell orders)
    /// @param _price price of the buy or sell order
    /// @param _isBuyOrder true for buy orders, false for sell orders

    function deposit(
        uint256 _quantity,
        uint256 _price,
        bool _isBuyOrder
    )
        external
        isPositive(_quantity)
        isPositive(_price)
    {
        // minimum amount deposited (avoid dust orders)
        _revertIfSuperiorTo(_minDeposit(_isBuyOrder), _quantity);

        // check if an identical order exists already, if so increase deposit, else create
        uint256 orderId = _getOrderIdInDepositIdsInUsers(msg.sender, _price, _isBuyOrder);
        if (orderId != 0) {
            increaseDeposit(orderId, _quantity);
        } else {
            // update orders: add order to orders, output the id of the new order
            uint256[MAX_POSITIONS] memory positionIds;
            uint256 newOrderId = _addOrderToOrders(msg.sender, _isBuyOrder, _quantity, _price, positionIds);
            // Update users: add orderId in depositIds array
            _addOrderIdInDepositIdsInUsers(newOrderId, msg.sender);
        }

        // _checkAllowanceAndBalance(msg.sender, _quantity, _isBuyOrder);
        require(_transferTokenFrom(msg.sender, _quantity, _isBuyOrder), "Transfer failed");

        emit Place(msg.sender, _quantity, _price, _isBuyOrder);
    }

    /// @notice lets users increase deposited assets in their order
    /// @param _orderId id of the order in which assets are deposited
    /// @param _increasedQuantity quantity of assets added

    function increaseDeposit(
        uint256 _orderId,
        uint256 _increasedQuantity
    )
        public
        orderExists(_orderId)
        isPositive(_increasedQuantity)
        onlyMaker(getMaker(_orderId))
    {
        bool isBid = orders[_orderId].isBuyOrder;

        // update orders: add quantity to orders
        _increaseOrderByQuantity(_orderId, _increasedQuantity);

        //_checkAllowanceAndBalance(msg.sender, _increasedQuantity, isBid);
        require(_transferTokenFrom(msg.sender, _increasedQuantity, isBid), "Transfer failed");

        emit Deposit(msg.sender, _orderId, _increasedQuantity);
    }

    /// @notice lets user partially or fully remove her order from the book
    /// Only non-borrowed assets can be removed
    /// @param _removedOrderId id of the order to be removed
    /// @param _quantityToRemove desired quantity of assets removed

    function withdraw(
        uint256 _removedOrderId,
        uint256 _quantityToRemove
    )
        external
        orderExists(_removedOrderId)
        isPositive(_quantityToRemove)
        onlyMaker(getMaker(_removedOrderId))
    {
        Order memory removedOrder = orders[_removedOrderId];

        // removal is allowed for non-borrowed assets net of minimum deposit
        uint256 removableQuantity = _min(_quantityToRemove, availableAssetsInOrder(_removedOrderId));

        // Remaining total deposits must be enough to secure maker's existing borrowing positions
        // Maker's excess collateral must remain positive after removal
        bool inQuoteToken = removedOrder.isBuyOrder;
        _revertIfSuperiorTo(removableQuantity, getUserExcessCollateral(removedOrder.maker, inQuoteToken));

        // reduce quantity in order, possibly to zero
        _reduceOrderByQuantity(_removedOrderId, removableQuantity);

        // remove orderId in depositIds array in users, if fully removed - deprecated
        // _removeOrderIdFromDepositIdsInUsers(removedOrder.maker, _removedOrderId);

        require(_transferTokenTo(msg.sender, removableQuantity, removedOrder.isBuyOrder), "Transfer failed");

        emit Withdraw(removedOrder.maker, removableQuantity, removedOrder.price, removedOrder.isBuyOrder);
    }

    /// @notice Let users take limit orders, regardless the orders' assets are borrowed or not
    /// taking liquidates **all** borrowing positions even if taking is partial
    /// taking of a collateral order triggers the borrower's liquidation for enough assets
    /// @param _takenOrderId id of the order to be taken
    /// @param _takenQuantity quantity of assets taken from the order

    function take(
        uint256 _takenOrderId,
        uint256 _takenQuantity
    )
        external
        orderExists(_takenOrderId)
        isPositive(_takenQuantity)
    {
        Order memory takenOrder = orders[_takenOrderId];

        // taking is allowed for non-borrowed assets, possibly net of minimum deposit if taking is partial
        uint256 takenableQuantity = _takenQuantity;
        if (_takenQuantity < nonBorrowedAssetsInOrder(_takenOrderId)) {
            takenableQuantity = availableAssetsInOrder(_takenOrderId);
        } else if (_takenQuantity > nonBorrowedAssetsInOrder(_takenOrderId)) { 
            revert("Taking is not allowed for borrowed assets");
        }

        _liquidateAssets(_takenOrderId);

        // quantity given by taker in exchange of _takenQuantity
        uint256 exchangedQuantity = _converts(takenableQuantity, takenOrder.price, takenOrder.isBuyOrder);

        // reduce quantity in order, possibly to zero
        _reduceOrderByQuantity(_takenOrderId, takenableQuantity);

        // remove orderId in depositIds array in users (check taking is full before) deprecated
        // _removeOrderIdFromDepositIdsInUsers(takenOrder.maker, _takenOrderId);

        // if a buy order is taken, the taker pays the quoteToken and receives the baseToken
        // _checkAllowanceAndBalance(msg.sender, exchangedQuantity, !takenOrder.isBuyOrder);
        require(_transferTokenFrom(msg.sender, exchangedQuantity, !takenOrder.isBuyOrder), "Transfer failed");
        require(_transferTokenTo(takenOrder.maker, exchangedQuantity, takenOrder.isBuyOrder), "Transfer failed");
        require(_transferTokenTo(msg.sender, takenableQuantity, takenOrder.isBuyOrder), "Transfer failed");

        emit Take(msg.sender, takenOrder.maker, takenableQuantity, takenOrder.price, takenOrder.isBuyOrder);
    }

    /// @notice Lets users borrow assets from orders (create or increase TO DO a borrowing position)
    /// Borrowers need to place orders first on the other side of the book with enough assets
    /// order is borrowable up to order's available assets or user's excess collateral
    /// @param _borrowedOrderId id of the order which assets are borrowed
    /// @param _borrowedQuantity quantity of assets borrowed from the order

    function borrow(
        uint256 _borrowedOrderId,
        uint256 _borrowedQuantity
    )
        external
        orderExists(_borrowedOrderId)
        isPositive(_borrowedQuantity)
    {
        Order memory borrowedOrder = orders[_borrowedOrderId];

        // borrow up to desired quantity or available assets
        uint256 borrowableQuantity = _min(
            _borrowedQuantity,
            availableAssetsInOrder(_borrowedOrderId)
        );

        // check available assets are not collateral for user's borrowing positions
        // For Bob to borrow USDC (quote token) from Alice's buy order, one must check that
        // Alice's excess collateral in USDC is enough to cover Bob's borrowing
        bool inQuoteToken = borrowedOrder.isBuyOrder;
        _revertIfSuperiorTo(borrowableQuantity, getUserExcessCollateral(borrowedOrder.maker, inQuoteToken));

        // check borrowed amount is enough collateralized by borrowers' orders
        // For Bob to borrow USDC (quote token) from Alice's buy order, one must check that
        // Bob's excess collateral in ETH is enough to cover Bob's borrowing
        _revertIfSuperiorTo(borrowableQuantity, getUserExcessCollateral(msg.sender, !inQuoteToken));   

        // update users: check if borrower already borrows from order,
        // if not, add orderId in borrowFromIds array, reverts if max position reached
        _addOrderIdInBorrowFromIdsInUsers(msg.sender, _borrowedOrderId);

        // update positions: create new or update existing borrowing position in positions
        // output the id of the new or updated borrowing position
        uint256 positionId = _addPositionToPositions(msg.sender, _borrowedOrderId, borrowableQuantity);

        // update orders: add new positionId in positionIds array
        // check first that position doesn't already exist
        // reverts if max number of positions is reached
        _AddPositionIdToPoisitionIdsInOrders(positionId, _borrowedOrderId);

        require(_transferTokenTo(msg.sender, borrowableQuantity, borrowedOrder.isBuyOrder), "Transfer failed");

        emit Borrow(msg.sender,_borrowedOrderId, borrowableQuantity, borrowedOrder.isBuyOrder);

    }

    /// @notice lets users decrease or close a borrowing position
    /// @param _repaidOrderId id of the order which assets are paid back
    /// @param _repaidQuantity quantity of assets paid back

    function repay(
        uint256 _repaidOrderId,
        uint256 _repaidQuantity
    )
        external
        orderExists(_repaidOrderId)
        isPositive(_repaidQuantity)
    {
        uint256 positionId = _getPositionIdInPositions(_repaidOrderId, msg.sender);
        _revertIfSuperiorTo(_repaidQuantity, positions[positionId].borrowedAssets);

        // update positions: decrease borrowedAssets, possibly to zero
        _reduceBorrowingByQuantity(positionId, _repaidQuantity);

        // remove positionId from positionIds in orders (check if removal is full before) = deprecated
        // _removePositionIdFromPositionIdsInOrders(positionId, _repaidOrderId);

        // remove repaid order id from borrowFromIds in users (check if removal is full before) = deprecated
        // _removeOrderIdFromBorrowFromIdsInUsers(msg.sender, _repaidOrderId);

        bool isBid = orders[_repaidOrderId].isBuyOrder;

        // _checkAllowanceAndBalance(msg.sender, _repaidQuantity, repaidOrder.isBuyOrder);
        require(_transferTokenFrom(msg.sender, _repaidQuantity, isBid), "Transfer failed");

        emit Repay(msg.sender, _repaidOrderId, _repaidQuantity, isBid);
    }

    ///////******* Internal functions *******///////

    /// @notice Liquidate **all** borrowing positions after taking an order, even if partial
    /// outputs the quantity liquidated
    /// doesn't perform external transfers
    /// @param _fromOrderId order from which borrowing positions must be cleared

    function _liquidateAssets(uint256 _fromOrderId)
        internal
    {
        uint256[MAX_POSITIONS] memory positionIds = orders[_fromOrderId].positionIds;
        // iterate on position ids which borrow from the order taken, liquidate position one by one
        for (uint256 i = 0; i < MAX_POSITIONS; i++) {
            if(_borrowingInPositionIsPositive(positionIds[i]))
                require(_liquidatePosition(positionIds[i]), "Some collateral couldn't be seized");
        }
    }

    /// @notice liquidate one borrowing position: seize collateral and write off debt for the same amount
    /// liquidation of a position is always full, i.e. borrower's debt is fully written off
    /// collateral is seized for the exact amount liquidated, i.e. no excess collateral is seized
    /// as multiple orders by the same borrower may collateralize the liquidated position:
    ///  - iterate on collateral orders made by borrower in the opposite currency
    ///  - seize collateral orders as they come, stops when borrower's debt is fully written off
    ///  - change internal balances
    /// doesn't execute final external transfer of assets
    /// @param _positionId id of the position to be liquidated

    function _liquidatePosition(uint256 _positionId)
        internal
        positionExists(_positionId)
        returns (bool)
    {
        Position memory position = positions[_positionId]; // position to be liquidated
        Order memory takenOrder = orders[position.orderId]; // order from which assets are taken
        // collateral to seize given borrowed quantity:
        uint256 collateralToSeize = _converts(position.borrowedAssets, takenOrder.price, takenOrder.isBuyOrder);
        // order id list of collateral orders to seize:
        uint256[MAX_ORDERS] memory depositIds = users[position.borrower].depositIds;
        for (uint256 i = 0; i < MAX_ORDERS; i++) {
            uint256 orderId = depositIds[i]; // order id from which assets are seized
            if (_orderQuantityIsPositive(orderId)) {
                if (collateralToSeize > orders[orderId].quantity) {
                    // borrower's order is fully seized, reduce order quantity to zero
                    _reduceOrderByQuantity(orderId, orders[orderId].quantity);
                    // update orders: remove position id from positionIds array = deprecated
                    // _removeOrderIdFromPositionIdsInOrders(position.borrower, orderId); 
                    // update users: remove seized order id from depositIds array = deprecated
                    // _removeOrderIdFromDepositIdsInUsers(position.borrower, orderId); 
                    collateralToSeize -= orders[orderId].quantity;
                } else {
                    // enough collateral assets are seized before borrower's order is fully seized
                    collateralToSeize = 0;
                    _reduceOrderByQuantity(orderId, collateralToSeize);
                    break;
                }
            }
        }
        // write off debt for the same amount as collateral seized
        positions[_positionId].borrowedAssets = 0;
        return (collateralToSeize == 0);

        // update users: remove taken order id in borrowFromIds array = deprecated
        // _removeOrderIdFromBorrowFromIdsInUsers(position.borrower, takenOrderId);
    }

    // tranfer ERC20 from contract to user/taker/borrower
    function _transferTokenTo(
        address _to,
        uint256 _quantity,
        bool _isBuyOrder
    ) internal isPositive(_quantity) returns (bool)
    {
        if (_isBuyOrder) return quoteToken.transfer(_to, _quantity);
        else return baseToken.transfer(_to, _quantity);
    }

    // transfer ERC20 from user/taker/repayBorrower to contract
    function _transferTokenFrom(
        address _from,
        uint256 _quantity,
        bool _isBuyOrder
    ) internal isPositive(_quantity) returns (bool)
    {
        if (_isBuyOrder) return quoteToken.transferFrom(_from, address(this), _quantity);
        else return baseToken.transferFrom(_from, address(this), _quantity);
    }

    // returns id of the new order
    function _addOrderToOrders(
        address _maker,
        bool _isBuyOrder,
        uint256 _quantity,
        uint256 _price,
        uint256[MAX_POSITIONS] memory _positionIds
    )
        internal 
        returns (uint256 orderId)
    {
        Order memory newOrder = Order({
            maker: _maker,
            isBuyOrder: _isBuyOrder,
            quantity: _quantity,
            price: _price,
            positionIds: _positionIds
        });
        orders[lastOrderId] = newOrder;
        orderId = lastOrderId;
        lastOrderId++;
    }

    // if order id is not in depositIds array, include it, otherwise do nothing
    function _addOrderIdInDepositIdsInUsers(
        uint256 _orderId,
        address _maker
    )
        internal
        orderExists(_orderId)
    {
        uint256 row = _getDepositIdsRowInUsers(_maker, _orderId);
        if (row == ABSENT) {
            bool fillRow = false;
            for (uint256 i = 0; i < MAX_ORDERS; i++) {
                if (!_orderQuantityIsPositive(users[_maker].depositIds[i])) {
                    users[_maker].depositIds[i] = _orderId;
                    fillRow = true;
                    break;
                }
                if (!fillRow) revert("Max number of orders reached for user");
            }
        }
    }

    function _removeOrderIdFromBorrowFromIdsInUsers(
        address _user,
        uint256 _orderId
    )
        internal
        orderExists(_orderId)
    {
        uint256 row = _getBorrowFromIdsRowInUsers(_user, _orderId);
        if (row != ABSENT) users[_user].borrowFromIds[row] = 0;
    }

    function _removeOrderIdFromPositionIdsInOrders(
        address _borrower,
        uint256 _orderId
    )
        internal 
        orderExists(_orderId)
    {
        // check borrower exists with a positive borrowed amount (otherwise ABSENT)
        uint256 row = _getPositionIdsRowInOrders(_orderId, _borrower);
        if (row != ABSENT) orders[_orderId].positionIds[row] = 0;
    }

    // update users: check if borrower already borrows from order,
    // if not, add order id in borrowFromIds array

    function _addOrderIdInBorrowFromIdsInUsers(
        address _borrower,
        uint256 _orderId
    )
        internal
        orderExists(_orderId)
    {
        uint256 row = _getBorrowFromIdsRowInUsers(_borrower, _orderId);
        if (row == ABSENT) {
            bool fillRow = false;
            for (uint256 i = 0; i < MAX_BORROWINGS; i++) {
                uint256 positionId = _getPositionIdsRowInOrders(_orderId, _borrower);
                if (!_borrowingInPositionIsPositive(positionId))
                {
                    users[_borrower].borrowFromIds[i] = _orderId;
                    fillRow = true;
                    break;
                }
                if (!fillRow) revert("Max number of positions reached for borrower");
            }
        }
    }

    function _removeOrderIdFromDepositIdsInUsers(
        address _user,
        uint256 _orderId
    )
        internal
        orderExists(_orderId)
    {
        if (orders[_orderId].quantity == 0) {
            uint256 row = _getDepositIdsRowInUsers(_user, _orderId);
            if (row != ABSENT) users[_user].depositIds[row] = 0;
        }
    }

    /// @notice update positions: add new position in positions mapping
    /// check first that position doesn't already exist
    /// returns existing or new position id in positions mapping
    /// @param _borrower address of the borrower
    /// @param _orderId id of the order from which assets are borrowed
    /// @param _borrowedQuantity quantity of assets borrowed (quoteToken for buy orders, baseToken for sell orders)

    function _addPositionToPositions(
        address _borrower,
        uint256 _orderId,
        uint256 _borrowedQuantity
    )
        internal
        orderExists(_orderId)
        isPositive(_borrowedQuantity)
        returns (uint256 positionId)
    {
        positionId = _getPositionIdInPositions(_orderId, _borrower);
        if (positionId != 0) {
            positions[positionId].borrowedAssets += _borrowedQuantity;
        } else {
            Position memory newPosition = Position({
                borrower: _borrower,
                orderId: _orderId,
                borrowedAssets: _borrowedQuantity
            });
            positions[lastPositionId] = newPosition;
            positionId = lastPositionId;
            lastPositionId++;
        }
    }

    // update positions: decrease borrowedAssets, borrowing = 0 is equivalent to delete position
    // quantity =< borrowing checked before the call

    function _reduceBorrowingByQuantity(
        uint256 _positionId,
        uint256 _quantity
    )
        internal
        positionExists(_positionId)
    {
        positions[_positionId].borrowedAssets -= _quantity;
        //if (positions[_positionId].borrowedAssets == 0) {delete positions[_positionId];} // already implictly deleted
    }

    // update orders: add new position id in positionIds array
    // check first that borrower does not borrow from order already
    // reverts if max number of positions is reached

    function _AddPositionIdToPoisitionIdsInOrders(
        uint256 _positionId,
        uint256 _orderId
    )
        internal
        orderExists(_orderId)
        positionExists(_positionId)
    {
        uint256 row = _getPositionIdsRowInOrders(_orderId, positions[_positionId].borrower);
        if (row == ABSENT) {
            bool fillRow = false;
            uint256[MAX_POSITIONS] memory positionIds = orders[_orderId].positionIds;
            for (uint256 i = 0; i < MAX_POSITIONS; i++) {
                if (!_borrowingInPositionIsPositive(positionIds[i])
                ) {
                    orders[_orderId].positionIds[i] = _positionId;
                    fillRow = true;
                    break;
                }
                if (!fillRow) revert("Max number of positions reached for order");
            }
        }
    }

    // remove positionId from positionIds in orders (check if removal is full before) (should be deprecated)

    function _removePositionIdFromPositionIdsInOrders(
        uint256 _positionId,
        uint256 _orderId
    )
        internal
        positionExists(_positionId)
        orderExists(_orderId)
    {
        Position memory position = positions[_positionId];
        if (position.borrowedAssets == 0) {
            uint256 row = _getPositionIdsRowInOrders(_orderId, position.borrower);
            if (row != ABSENT) orders[_orderId].positionIds[row] = 0;
        }
    }

    // increase quantity offered in order, delete order if emptied
    function _increaseOrderByQuantity(
        uint256 _orderId,
        uint256 _quantity
    )
        internal
        orderExists(_orderId)
        isPositive(_quantity)
    {
        orders[_orderId].quantity += _quantity;
    }

    // reduce quantity offered in order, if emptied, order is implictly delete
    // reduced quantity =< order quantity has been check before the call

    function _reduceOrderByQuantity(
        uint256 _orderId,
        uint256 _quantity
    )
        internal
        orderExists(_orderId)
    {
        orders[_orderId].quantity -= _quantity;
    }

    //////////********* View functions HERE *********/////////

    // user exists if she has at least one order with positive quantity

    //  function _userHasDeposit(address _user)
    //     internal view
    //     returns (bool hasDeposit)
    // {
    //     hasDeposit = false;
    //     uint256[MAX_ORDERS] memory depositIds = users[_user].depositIds;
    //     for (uint256 i = 0; i < MAX_ORDERS; i++) {
    //         if (_orderQuantityIsPositive(depositIds[i])) {
    //             hasDeposit = true;
    //             break;
    //         }
    //     }
    //     return hasDeposit;
    // }
    
    function _revertIfOrderDoesntExist(uint256 _orderId)
        internal view
    {
        require(_orderQuantityIsPositive(_orderId), "Order does not exist");
    }

    function _orderQuantityIsPositive(uint256 _orderId)
        internal view
        returns (bool)
    {
        return (orders[_orderId].quantity > 0);
    }

    function _onlyMaker(address maker)
        internal view
    {
        require(maker == msg.sender, "removeOrder: Only the maker can remove the order");
    }

    function _RevertIfPositionDoesntExist(uint256 _positionId)
        internal view
    {
        require(_borrowingInPositionIsPositive(_positionId), "Borrowing position does not exist");
    }

    function _borrowingInPositionIsPositive(uint256 _positionId)
        internal view
        returns (bool)
    {
        return (positions[_positionId].borrowedAssets > 0);
    }

    // get address of maker based on order id
    function getMaker(uint256 _orderId)
        public view
        orderExists(_orderId)
        returns (address)
    {
        return orders[_orderId].maker;
    }

    // check if user is a borrower of quote or base token
    // a user who borrows from buy oders borrows quote token

    // function isUserBorrower(
    //     address _user,
    //     bool _inQuoteToken
    // ) 
    //     public view
    //     returns (bool isBorrower)
    // {
    //     isBorrower = false;
    //     uint256[MAX_BORROWINGS] memory borrowFromIds = users[_user].borrowFromIds;
    //     for (uint256 i = 0; i < MAX_BORROWINGS; i++) {
    //         Order memory borrowedOrder = orders[borrowFromIds[i]];
    //         if (
    //             borrowFromIds[i] != 0 &&
    //             borrowedOrder.isBuyOrder == _inQuoteToken &&
    //             borrowedOrder.quantity > 0
    //         ) {
    //             isBorrower = true;
    //             break;
    //         }
    //     }
    // }

    // check allowance and balance before ERC20 transfer // deprecated

    // function _checkAllowanceAndBalance(
    //     address _user,
    //     uint256 _quantity,
    //     bool _isBuyOrder
    // )
    //     internal view
    //     isPositive(_quantity)
    // {
    //     if (_isBuyOrder) {
    //         require(quoteToken.balanceOf(_user) >= _quantity,
    //             "quote token: Insufficient balance");
    //         require(quoteToken.allowance(_user, address(this)) >= _quantity,
    //             "quote token: Insufficient allowance");
    //     } else {
    //         require(baseToken.balanceOf(_user) >= _quantity,
    //             "base token: Insufficient balance");
    //         require(baseToken.allowance(_user, address(this)) >= _quantity,
    //             "base token: Insufficient allowance");
    //     }
    // }

    // sum all assets deposited by user in the quote or base token

    function getUserTotalDeposit(
        address _user,
        bool _inQuoteToken
    )
        public view
        returns (uint256 totalDeposit)
    {
        uint256[MAX_ORDERS] memory depositIds = users[_user].depositIds;
        totalDeposit = 0;
        for (uint256 i = 0; i < MAX_ORDERS; i++) {
            if (orders[depositIds[i]].isBuyOrder == _inQuoteToken)
                totalDeposit += orders[depositIds[i]].quantity;
        }
    }
    
    // // get borrower's total Debt in the quote or base token
    // function getBorrowerTotalDebt(
    //     address _borrower,
    //     bool _inQuoteToken
    // )
    //     public view
    //     returns (uint256 totalDebt)
    // {
    //     uint256[MAX_BORROWINGS] memory borrowFromIds = users[_borrower].borrowFromIds;
    //     totalDebt = 0;
    //     for (uint256 i = 0; i < MAX_BORROWINGS; i++) {
    //         uint256 row = _getPositionIdsRowInOrders(borrowFromIds[i], _borrower);
    //         if (orders[borrowFromIds[i]].isBuyOrder == _inQuoteToken)
    //             totalDebt += positions[row].borrowedAssets;
    //     }
    // }

    // total assets borrowed by other users from _user in base or quote token
    function getUserTotalBorrowedAssets(
        address _user,
        bool _inQuoteToken
    )
        public view
        returns (uint256 totalBorrowedAssets)
    {
        uint256[MAX_ORDERS] memory orderIds = users[_user].depositIds;
        totalBorrowedAssets = 0;
        for (uint256 i = 0; i < MAX_ORDERS; i++) {
            totalBorrowedAssets += _getOrderBorrowedAssets(orderIds[i], _inQuoteToken);
        }
    }

    // total assets borrowed from order in base or quote tokens
    function _getOrderBorrowedAssets(
        uint256 _orderId,
        bool _inQuoteToken
        )
        public view
        returns (uint256 borrowedAssets)
    {
        borrowedAssets = 0;
        if (_orderQuantityIsPositive(_orderId)) {
            if (orders[_orderId].isBuyOrder == _inQuoteToken) {
                uint256[MAX_POSITIONS] memory positionIds = orders[_orderId].positionIds;
                for (uint256 i = 0; i < MAX_POSITIONS; i++) {
                    borrowedAssets += positions[positionIds[i]].borrowedAssets;
                }
            }
        }
    }

    // borrower's total collateral needed to secure his debt in the quote or base token
    // if needed collateral is in quote token, borrowed order is a sell order
    // Ex: Alice deposits 3 ETH to sell at 2100; Bob borrows 2 ETH and needs 2*2100 = 4200 USDC as collateral

    function getBorrowerNeededCollateral(
        address _borrower,
        bool _inQuoteToken
    )
        public view
        returns (uint256 totalNeededCollateral)
    {
        totalNeededCollateral = 0;
        uint256[MAX_BORROWINGS] memory borrowedIds = users[_borrower].borrowFromIds;
        for (uint256 i = 0; i < MAX_BORROWINGS; i++) {
            Order memory order = orders[borrowedIds[i]]; // order id which assets are borrowed
            if (order.isBuyOrder != _inQuoteToken) {
                uint256 positionIdRow = _getPositionIdsRowInOrders(borrowedIds[i], _borrower);
                if (positionIdRow != ABSENT) {
                    Position memory position = positions[positionIdRow];
                    uint256 collateral = _converts(
                        position.borrowedAssets,
                        order.price,
                        order.isBuyOrder
                    );
                    totalNeededCollateral += collateral;
                }
            }
        }
    }

    // get user's excess collateral in the quote or base token
    // excess collateral = total deposits - collateral assets - borrowed assets

    function getUserExcessCollateral(
        address _user,
        bool _inQuoteToken
    )
        public view
        returns (uint256 excessCollateral) {
        excessCollateral =
            getUserTotalDeposit(_user, _inQuoteToken) -
            getBorrowerNeededCollateral(_user, _inQuoteToken) -
            getUserTotalBorrowedAssets(_user, _inQuoteToken);
    }

    // get quantity of assets lent by order
    function getTotalAssetsLentByOrder(uint256 _orderId)
        public view
        orderExists(_orderId)
        returns (uint256 totalLentAssets)
    {
        uint256[MAX_POSITIONS] memory positionIds = orders[_orderId].positionIds;
        totalLentAssets = 0;
        for (uint256 i = 0; i < MAX_POSITIONS; i++) {
            totalLentAssets += positions[positionIds[i]].borrowedAssets;
        }
    }

    // get quantity of assets available in order: order quantity - assets lent - minimum deposit
    function availableAssetsInOrder(uint256 _orderId)
        public view
    returns (uint256 availableAssets)
    {
        uint256 nonAvailableAssets = getTotalAssetsLentByOrder(_orderId) + _minDeposit(orders[_orderId].isBuyOrder);
        availableAssets = _min(0, orders[_orderId].quantity - nonAvailableAssets);
    }

    // get quantity of assets available in order: order quantity - assets lent
    function nonBorrowedAssetsInOrder(uint256 _orderId)
        public view
    returns (uint256 nonBorrowedAssets)
    {
        nonBorrowedAssets = _min(0, orders[_orderId].quantity - getTotalAssetsLentByOrder(_orderId));
    }

    // find if user placed order id
    // if so, outputs its row in depositIds array

    function _getDepositIdsRowInUsers(
        address _user,
        uint256 _orderId // in the depositIds array of users
    )
        internal view
        orderExists(_orderId)
        returns (uint256 depositIdsRow)
    {
        depositIdsRow = ABSENT;
        uint256[MAX_ORDERS] memory depositIds = users[_user].depositIds;
        for (uint256 i = 0; i < MAX_ORDERS; i++) {
            if (depositIds[i] == _orderId) {
                depositIdsRow = i;
                break;
            }
        }
    }

    // check if user borrows from order
    // if so, returns row in borrowFromIds array

    function _getBorrowFromIdsRowInUsers(
        address _borrower,
        uint256 _orderId // in the borrowFromIds array of users
    )
        internal view
        orderExists(_orderId)
        returns (uint256 borrowFromIdsRow)
    {
        borrowFromIdsRow = ABSENT;
        uint256[MAX_BORROWINGS] memory borrowFromIds = users[_borrower].borrowFromIds;
        for (uint256 i = 0; i < MAX_BORROWINGS; i++) {
            if (borrowFromIds[i] == _orderId) {
                borrowFromIdsRow = i;
                break;
            }
        }
    }

    // check if an order already exists with the same user and limit price
    // if so, returns order id
    
    function _getOrderIdInDepositIdsInUsers(
        address _user,
        uint256 _price,
        bool _isBuyOrder
    )
        internal view
        isPositive(_price)
        returns (uint256 orderId)
    {
        orderId = 0;
        uint256[MAX_ORDERS] memory depositIds = users[_user].depositIds;
        for (uint256 i = 0; i < MAX_ORDERS; i++) {
            if (
                orders[depositIds[i]].price == _price &&
                orders[depositIds[i]].isBuyOrder == _isBuyOrder
            ) {
                orderId = depositIds[i];
                break;
            }
        }
    }

    // find in positionIds[] from orders if _borrower borrows from _orderId
    // and, if so, at which row in the positionId array

    function _getPositionIdsRowInOrders(
        uint256 _orderId,
        address _borrower
    )
        internal view
        orderExists(_orderId)
        returns (uint256 positionIdRow)
    {
        positionIdRow = ABSENT;
        uint256[MAX_POSITIONS] memory positionIds = orders[_orderId].positionIds;
        for (uint256 i = 0; i < MAX_POSITIONS; i++) {
            if (positions[positionIds[i]].borrower == _borrower &&
                positions[positionIds[i]].borrowedAssets > 0) {
                positionIdRow = i;
                break;
            }
        }
    }

    // retrive position id from order id and borrower address
    function _getPositionIdInPositions(
        uint256 _orderId,
        address _borrower
    )
        internal view
        orderExists(_orderId)
        returns (uint256 positionId)
    {
        uint256 row = _getPositionIdsRowInOrders(_orderId, _borrower);
        if (row != ABSENT) positionId = orders[_orderId].positionIds[row];
        else positionId = 0;
    }

    //////////********* Pure functions *********/////////

    function _checkPositive(uint256 _var)
        internal pure
    {
        require(_var > 0, "Must be positive");
    }
    
    function _converts(
        uint256 _quantity,
        uint256 _price,
        bool _inQuoteToken // type of the asset to convert to (quote or base token)
    )
        internal pure
        returns (uint256 convertedQuantity)
    {
        convertedQuantity = _inQuoteToken ?
            _quantity / _price :
            _quantity * _price;
    }

    function _minDeposit(bool _isBuyOrder)
        internal pure
        returns (uint256 minAssets)
    {
        minAssets = _isBuyOrder ? MIN_DEPOSIT_QUOTE : MIN_DEPOSIT_BASE;
    }
    
    function _revertIfSuperiorTo(
        uint256 _reducedQuantity,
        uint256 _totalQuantity
    )
        internal pure
        isPositive(_reducedQuantity)
        isPositive(_totalQuantity)
    {
        require(_reducedQuantity <= _totalQuantity, "reduced quantity exceeds total quantity");
    }

    function _min(
        uint256 _a,
        uint256 _b
    )
        internal pure
    returns (uint256 __min)
    {
        __min = _a < _b ? _a : _b;
    }
}
