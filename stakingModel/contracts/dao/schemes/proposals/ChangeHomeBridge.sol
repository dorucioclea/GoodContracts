pragma solidity >0.5.4;

import "@daostack/arc/contracts/controller/Avatar.sol";
import "@daostack/arc/contracts/controller/ControllerInterface.sol";

/* @title Scheme for switching to AMB bridge
 */
contract ChangeHomeBridge {
    event HomeBridgeDeployed(
        address indexed _homeBridge,
        address indexed _homeValidators,
        address indexed _token,
        uint256 _blockNumber
    );

    address public bridgeContract;
    Avatar avatar;

    /* @dev constructor. Sets the factory address. Reverts if given address is null
     * @param _factory The address of the bridge factory
     */
    constructor(Avatar _avatar, address _bridgeContract) public {
        require(_bridgeContract != address(0), "Factory must not be null");
        bridgeContract = _bridgeContract;
        avatar = _avatar;
    }

    /* @dev Adds the bridge address to minters, deploys the home bridge on
     * current network, and then self-destructs, transferring any ether on the
     * contract to the avatar. Reverts if scheme is not registered
     */
    function setBridge() public {
        ControllerInterface controller = ControllerInterface(avatar.owner());
        (bool ok, ) = controller.genericCall(
            address(avatar.nativeToken()),
            abi.encodeWithSignature("addMinter(address)", bridgeContract),
            avatar,
            0
        );

        require(ok, "Adding Bridge as minter failed");

        (bool deployOk, ) = controller.genericCall(
            address(avatar.nativeToken()),
            abi.encodeWithSignature("setBridgeContract(address)", bridgeContract),
            avatar,
            0
        );

        require(deployOk, "Calling setBridgeContract failed");

        selfdestruct(address(avatar));
    }
}
