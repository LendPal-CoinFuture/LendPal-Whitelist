// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @title AccessRegistry
/// @notice 超级管理员管普通管理员。普通管理员只管自己加入的白名单。
///         普通管理员不能添加、删除、修改任何管理员。
///         普通管理员不能删除或修改其他普通管理员加入的白名单。
///         合约里没有修改白名单记录和管理员身份的函数。
contract AccessRegistry is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    /// @notice 普通管理员人数上限的默认值。超级管理员不占名额。
    ///         还没调用 setAdminLimit 时，按这个数字计算。
    uint256 public constant DEFAULT_ADMIN_LIMIT = 200;

    /// @notice 翻页时一页最多 50 条。
    uint256 public constant MAX_PAGE_SIZE = 50;

    /// @notice 白名单备注最长 64 字节。空备注也可以。
    uint256 public constant MAX_NOTE_LENGTH = 64;

    /// @notice 存储版本。第一次部署后保持为 1。
    uint256 public constant EXPECTED_LAYOUT_VERSION = 1;

    /// @notice 0 普通地址，1 普通管理员，2 超级管理员。
    enum Role {
        None,
        Admin,
        SuperAdmin
    }

    /// @notice 全部名单。字段顺序在第一次部署后不能再改。
    ///         新字段只能加在 layoutVersion 后面。
    /// @custom:storage-location erc7201:ethereumdapp.access.registry
    struct Layout {
        // 地址 => 在管理员数组中的位置 + 1。0 表示不是普通管理员。
        mapping(address => uint256) adminIndexPlusOne;
        address[] adminList;
        // 用户地址 => 把他加入白名单的人。空地址表示不在白名单。
        mapping(address => address) whitelistAddedBy;
        address[] whitelistList;
        mapping(address => uint256) whitelistIndexPlusOne;
        // 每个管理员自己的白名单，用来互相隔离。
        mapping(address => address[]) adminWhitelist;
        mapping(address => mapping(address => uint256)) adminWhitelistIndexPlusOne;
        uint256 layoutVersion;
        // 超级管理员设置过的人数上限。0 并且 adminLimitSet 为假时，按默认 200 计算。
        uint256 adminLimit;
        bool adminLimitSet;
        // 用户地址 => 加入时写下的备注。旧记录默认为空字符串。
        mapping(address => string) whitelistNotes;
        // 普通管理员地址 => 加入时写下的备注。旧记录默认为空字符串。
        mapping(address => string) adminNotes;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("ethereumdapp.access.registry")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant LAYOUT_SLOT =
        0xd305b90518e6fe535c399942b2c8ed71039b6599030b4fa85d6ed3cf0b93cb00;

    error EthRejected();
    error UpgradeCalldataDisabled();
    error RenounceDisabled();
    error ZeroAddress();
    error AlreadyListed();
    error UserAlreadyWhitelisted();
    error NotListed();
    error NotOperator();
    error NotEntryOwner();
    error OwnerCannotBeAdmin();
    error AdminCapacityReached();
    error AdminLimitTooSmall();
    error NoteTooLong();

    event AdminAdded(address indexed account, string note);
    event AdminRemoved(address indexed account);
    event WhitelistAdded(address indexed account, address indexed operator, string note);
    event WhitelistRemoved(address indexed account, address indexed operator);
    event WhitelistReassigned(address indexed from, address indexed to, uint256 count);
    event AdminLimitUpdated(uint256 limit);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        // 逻辑合约自己不能被初始化。初始化只发生在代理合约上。
        _disableInitializers();
    }

    /// @notice 创建代理时调用一次，写入第一位超级管理员。
    function initialize(address initialOwner) external initializer {
        __Ownable_init(initialOwner);
        __Ownable2Step_init();
        Layout storage $ = _layout();
        $.layoutVersion = EXPECTED_LAYOUT_VERSION;
        $.adminLimit = DEFAULT_ADMIN_LIMIT;
        $.adminLimitSet = true;
    }

    /// @notice 更换逻辑合约。不能附带以太币，也不能附带额外调用。
    ///         只有超级管理员能成功。
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override {
        if (msg.value != 0) revert EthRejected();
        if (data.length != 0) revert UpgradeCalldataDisabled();
        super.upgradeToAndCall(newImplementation, data);
    }

    /// @dev 升级权限只给超级管理员。普通管理员到不了这里。
    function _authorizeUpgrade(address) internal view override onlyOwner {}

    /// @notice 发起超级管理员交接。新地址自己确认后才生效。
    ///         传入空地址只取消未完成的交接。
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner != address(0) && _layout().adminIndexPlusOne[newOwner] != 0) {
            revert OwnerCannotBeAdmin();
        }
        super.transferOwnership(newOwner);
    }

    /// @notice 新超级管理员确认接手。他还在普通管理员名单里时会失败。
    ///         确认生效前，原超级管理员本人加入的用户改记到新地址名下。
    ///         普通管理员加入的用户不改归属。
    function acceptOwnership() public override {
        address nextOwner = pendingOwner();
        if (nextOwner != msg.sender) revert OwnableUnauthorizedAccount(msg.sender);
        if (_layout().adminIndexPlusOne[msg.sender] != 0) revert OwnerCannotBeAdmin();
        _reassignSuperAdminWhitelist(owner(), nextOwner);
        super.acceptOwnership();
    }

    /// @notice 父合约留下的函数。调用一定失败，超级管理员不能被交到空地址。
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice 添加普通管理员。只有超级管理员能调用。
    ///         普通管理员没有这个入口，不能把别人加为管理员，也不能把自己抬成超级管理员。
    ///         备注可以是空字符串，最长 64 字节。
    function addAdmin(address account, string calldata note) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (account == owner()) revert OwnerCannotBeAdmin();
        if (pendingOwner() != address(0) && account == pendingOwner()) revert OwnerCannotBeAdmin();
        if (bytes(note).length > MAX_NOTE_LENGTH) revert NoteTooLong();

        Layout storage $ = _layout();
        if ($.adminIndexPlusOne[account] != 0) revert AlreadyListed();
        if ($.adminList.length >= _adminLimit($)) revert AdminCapacityReached();
        _add($.adminIndexPlusOne, $.adminList, account);
        $.adminNotes[account] = note;
        emit AdminAdded(account, note);
    }

    /// @notice 修改普通管理员人数上限。只有超级管理员能调用。
    ///         新上限不能小于当前已经在任的普通管理员人数。
    ///         超级管理员本人不占这个名额。
    function setAdminLimit(uint256 newLimit) external onlyOwner {
        Layout storage $ = _layout();
        if (newLimit < $.adminList.length) revert AdminLimitTooSmall();
        $.adminLimit = newLimit;
        $.adminLimitSet = true;
        emit AdminLimitUpdated(newLimit);
    }

    /// @notice 当前普通管理员人数上限。
    ///         旧版本升级后如果还没设置过，返回默认值 200。
    function adminLimit() external view returns (uint256) {
        return _adminLimit(_layout());
    }

    /// @notice 移除普通管理员。只有超级管理员能调用。
    ///         普通管理员调用会失败。不能删除其他普通管理员，也不能删除自己的管理员身份。
    ///         没有修改管理员的函数。
    ///         只删除管理员身份。他之前添加的用户继续留在白名单里，添加人不变。
    function removeAdmin(address account) external onlyOwner {
        Layout storage $ = _layout();
        _remove($.adminIndexPlusOne, $.adminList, account);
        delete $.adminNotes[account];
        emit AdminRemoved(account);
    }

    /// @notice 读取某个普通管理员的备注。不是管理员时返回空字符串。
    function adminNoteOf(address account) external view returns (string memory) {
        return _layout().adminNotes[account];
    }

    /// @notice 普通管理员人数。任何人都能读。
    function adminCount() external view returns (uint256) {
        return _layout().adminList.length;
    }

    /// @notice 全部普通管理员。任何人都能读。
    function getAdmins() external view returns (address[] memory items) {
        address[] storage list = _layout().adminList;
        items = new address[](list.length);
        for (uint256 i = 0; i < list.length; i++) {
            items[i] = list[i];
        }
    }

    /// @notice 把用户加入白名单，并记下当前调用人和备注。
    ///         这个地址已经被人加入时会失败，不能改记到自己名下。
    ///         备注可以是空字符串，最长 64 字节。
    function addToWhitelist(address account, string calldata note) external onlyOperator {
        if (account == address(0)) revert ZeroAddress();
        if (bytes(note).length > MAX_NOTE_LENGTH) revert NoteTooLong();

        Layout storage $ = _layout();
        if ($.whitelistAddedBy[account] != address(0)) revert UserAlreadyWhitelisted();

        $.whitelistAddedBy[account] = msg.sender;
        $.whitelistIndexPlusOne[account] = $.whitelistList.length + 1;
        $.whitelistList.push(account);
        $.adminWhitelistIndexPlusOne[msg.sender][account] = $.adminWhitelist[msg.sender].length + 1;
        $.adminWhitelist[msg.sender].push(account);
        $.whitelistNotes[account] = note;

        emit WhitelistAdded(account, msg.sender, note);
    }

    /// @notice 移出白名单。没有修改函数。
    ///         普通管理员只能删除自己加入的用户。
    ///         删除其他普通管理员加入的用户会失败。
    ///         超级管理员可以删除任何一条。
    function removeFromWhitelist(address account) external onlyOperator {
        Layout storage $ = _layout();
        address addedBy = $.whitelistAddedBy[account];
        if (addedBy == address(0)) revert NotListed();
        if (msg.sender != owner() && addedBy != msg.sender) revert NotEntryOwner();

        _remove($.whitelistIndexPlusOne, $.whitelistList, account);
        _remove($.adminWhitelistIndexPlusOne[addedBy], $.adminWhitelist[addedBy], account);
        delete $.whitelistAddedBy[account];
        delete $.whitelistNotes[account];

        emit WhitelistRemoved(account, msg.sender);
    }

    /// @notice 读取某个白名单地址的备注。不在名单里时返回空字符串。
    function whitelistNoteOf(address account) external view returns (string memory) {
        return _layout().whitelistNotes[account];
    }

    /// @notice 全部白名单人数。任何人都能读。
    function whitelistCount() external view returns (uint256) {
        return _layout().whitelistList.length;
    }

    /// @notice 分页读取全部白名单。任何人都能读。
    function getWhitelistPage(uint256 offset, uint256 limit) external view returns (address[] memory items) {
        return _page(_layout().whitelistList, offset, limit);
    }

    /// @notice 当前调用人自己加入的白名单人数。没有记录时返回 0。
    function myWhitelistCount() external view returns (uint256) {
        return _layout().adminWhitelist[msg.sender].length;
    }

    /// @notice 分页读取当前调用人自己加入的白名单。
    function getMyWhitelistPage(uint256 offset, uint256 limit) external view returns (address[] memory items) {
        return _page(_layout().adminWhitelist[msg.sender], offset, limit);
    }

    /// @notice 查询一个地址的身份。
    function roleOf(address account) external view returns (Role) {
        if (account == owner()) return Role.SuperAdmin;
        if (_layout().adminIndexPlusOne[account] != 0) return Role.Admin;
        return Role.None;
    }

    /// @notice 产品进门时调用。只回答在或不在，不返回是谁加入的。
    ///         超级管理员、普通管理员视为已准入（与白名单用户同等）。
    function isWhitelisted(address account) external view returns (bool) {
        if (account == address(0)) return false;
        if (account == owner()) return true;
        Layout storage $ = _layout();
        if ($.adminIndexPlusOne[account] != 0) return true;
        return $.whitelistAddedBy[account] != address(0);
    }

    /// @notice 存储版本。升级后应仍为 1。
    function layoutVersion() external view returns (uint256) {
        return _layout().layoutVersion;
    }

    /// @notice 转账到合约会失败。
    receive() external payable {
        revert EthRejected();
    }

    /// @notice 调用不存在的函数会失败。
    fallback() external payable {
        revert EthRejected();
    }

    /// @dev 没设置过时用默认上限。设置过之后，以超级管理员写入的数字为准，包括 0。
    function _adminLimit(Layout storage $) private view returns (uint256) {
        if (!$.adminLimitSet) return DEFAULT_ADMIN_LIMIT;
        return $.adminLimit;
    }

    /// @dev 超级管理员或普通管理员可以通过。
    ///      只挂在白名单函数上。删除管理员、升级、交接不使用它。
    modifier onlyOperator() {
        if (msg.sender != owner() && _layout().adminIndexPlusOne[msg.sender] == 0) {
            revert NotOperator();
        }
        _;
    }

    /// @dev 交接生效前调用。只改原超级管理员加入的那些用户。
    ///      用户仍在总白名单里。普通管理员的名单不动。
    function _reassignSuperAdminWhitelist(address from, address to) private {
        if (from == to) return;

        Layout storage $ = _layout();
        address[] storage fromList = $.adminWhitelist[from];
        uint256 count = fromList.length;
        for (uint256 i = 0; i < count; i++) {
            address account = fromList[i];
            if ($.whitelistAddedBy[account] != from) revert NotListed();

            delete $.adminWhitelistIndexPlusOne[from][account];
            $.whitelistAddedBy[account] = to;
            $.adminWhitelistIndexPlusOne[to][account] = $.adminWhitelist[to].length + 1;
            $.adminWhitelist[to].push(account);
        }

        delete $.adminWhitelist[from];
        if (count != 0) emit WhitelistReassigned(from, to, count);
    }

    /// @dev 名单存在这个固定槽位。槽位数值部署后不能改。
    function _layout() private pure returns (Layout storage $) {
        bytes32 slot = LAYOUT_SLOT;
        assembly {
            $.slot := slot
        }
    }

    function _page(address[] storage list, uint256 offset, uint256 limit) private view returns (address[] memory items) {
        if (limit > MAX_PAGE_SIZE) limit = MAX_PAGE_SIZE;
        if (offset >= list.length || limit == 0) return new address[](0);

        uint256 end = offset + limit;
        if (end > list.length) end = list.length;

        items = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            items[i - offset] = list[i];
        }
    }

    /// @dev 0 表示不在名单里。在名单里时，存的是数组下标加 1。
    function _add(mapping(address => uint256) storage indexPlusOne, address[] storage list, address account) private {
        if (account == address(0)) revert ZeroAddress();
        if (indexPlusOne[account] != 0) revert AlreadyListed();

        indexPlusOne[account] = list.length + 1;
        list.push(account);
    }

    /// @dev 删除时把最后一名挪到空位，再丢掉末尾。
    ///      名单 [A, B, C] 删掉 B 之后剩下 [A, C]。
    function _remove(
        mapping(address => uint256) storage indexPlusOne,
        address[] storage list,
        address account
    ) private {
        uint256 current = indexPlusOne[account];
        if (current == 0) revert NotListed();

        uint256 index = current - 1;
        uint256 lastIndex = list.length - 1;
        if (index != lastIndex) {
            address lastAccount = list[lastIndex];
            list[index] = lastAccount;
            indexPlusOne[lastAccount] = index + 1;
        }

        list.pop();
        delete indexPlusOne[account];
    }
}
