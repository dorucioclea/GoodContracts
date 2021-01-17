// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;

import "@openzeppelin/contracts-upgradeable/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/cryptography/MerkleProofUpgradeable.sol";

import "./Reputation.sol";
import "../Interfaces.sol";

/**
 * @title InvitesV1 contract that handles invites with pre allocated bounty pool
 * 1.1 adds invitee bonus
 */
contract GReputation is Reputation {
	using SafeMathUpgradeable for uint256;

	string public constant name = "GReputation";

	/// @notice The EIP-712 typehash for the contract's domain
	bytes32 public constant DOMAIN_TYPEHASH =
		keccak256(
			"EIP712Domain(string name,uint256 chainId,address verifyingContract)"
		);

	/// @notice The EIP-712 typehash for the delegation struct used by the contract
	bytes32 public constant DELEGATION_TYPEHASH =
		keccak256("Delegation(address delegate,uint256 nonce,uint256 expiry)");

	struct BlockchainState {
		bytes32 stateHash;
		uint256 hashType;
		uint256 totalSupply;
		uint256 blockNumber;
		uint256[5] __reserevedSpace;
	}

	/// @notice A record of states for signing / validating signatures
	mapping(address => uint256) public nonces;

	mapping(bytes32 => BlockchainState[]) public blockchainStates;
	mapping(bytes32 => mapping(address => uint256)) public stateHashBalances;

	bytes32[] public activeBlockchains;

	//keep map of user -> delegate
	mapping(address => address) public delegates;

	//map of user non delegatd + delegated votes to user. this is used for actual voting
	mapping(address => uint256[]) public activeVotes;

	//keep map of user -> delegatees[]
	mapping(address => address[]) public delegatees;

	/// @notice An event thats emitted when a delegate account's vote balance changes
	event DelegateVotesChanged(
		address indexed delegate,
		address indexed delegator,
		uint256 previousBalance,
		uint256 newBalance
	);

	function _mint(address _user, uint256 _amount)
		internal
		override
		returns (uint256)
	{
		super._mint(_user, _amount);
		address delegator = delegates[_user];
		delegator = delegator != address(0) ? delegator : _user;
		delegates[_user] = delegator;
		uint256 previousVotes = getVotes(delegator);

		_updateDelegateVotes(
			delegator,
			_user,
			previousVotes,
			previousVotes.add(_amount)
		);
		return _amount;
	}

	function _burn(address _user, uint256 _amount)
		internal
		override
		returns (uint256)
	{
		uint256 amountBurned = super._burn(_user, _amount);
		address delegator = delegates[_user];
		delegator = delegator != address(0) ? delegator : _user;
		delegates[_user] = delegator;
		uint256 previousVotes = getVotes(delegator);

		_updateDelegateVotes(
			delegator,
			_user,
			previousVotes,
			previousVotes.sub(amountBurned)
		);

		return amountBurned;
	}

	function delegateOf(address _user) public view returns (address) {
		return delegates[_user];
	}

	function setBlockchainStateHash(
		string memory _id,
		bytes32 _hash,
		uint256 _totalSupply
	) public onlyOwner {
		bytes32 idHash = keccak256(bytes(_id));

		//dont consider rootState as blockchain,  it is a special state hash
		bool isRootState = idHash == keccak256(bytes("rootState"));
		require(
			!isRootState || super.totalSupplyAt(block.number) == 0,
			"rootState already created"
		);

		uint256 i = 0;
		for (; !isRootState && i < activeBlockchains.length; i++) {
			if (activeBlockchains[i] == idHash) break;
		}

		//if new blockchain
		if (!isRootState && i == activeBlockchains.length) {
			activeBlockchains.push(idHash);
		}

		if (isRootState) {
			updateValueAtNow(totalSupplyHistory, _totalSupply);
		}

		BlockchainState memory state;
		state.stateHash = _hash;
		state.totalSupply = _totalSupply;
		state.blockNumber = block.number;
		blockchainStates[idHash].push(state);
	}

	function getVotesAt(
		address _user,
		bool _global,
		uint256 _blockNumber
	) public view returns (uint256) {
		uint256 startingBalance = getValueAt(activeVotes[_user], _blockNumber);

		if (_global) {
			for (uint256 i = 0; i < activeBlockchains.length; i++) {
				startingBalance = startingBalance.add(
					getVotesAtBlockchain(
						activeBlockchains[i],
						_user,
						_blockNumber
					)
				);
			}
		}

		return startingBalance;
	}

	/**
	 * @dev returns aggregated reputation in all blockchains and delegated
	 */
	function getVotes(address _user) public view returns (uint256) {
		return getVotesAt(_user, true, block.number);
	}

	/**
	 * @dev returns aggregated reputation in all blockchains and delegated
	 */
	function getVotesAt(address _user, uint256 _blockNumber)
		public
		view
		returns (uint256)
	{
		return getVotesAt(_user, true, _blockNumber);
	}

	/**
	 * @dev returns total supply in current blockchain (super.balanceOfAt)
	 */
	function totalSupplyLocal(uint256 _blockNumber)
		public
		view
		returns (uint256)
	{
		return super.totalSupplyAt(_blockNumber);
	}

	function totalSupplyAt(uint256 _blockNumber)
		public
		view
		override
		returns (uint256)
	{
		uint256 startingSupply = super.totalSupplyAt(_blockNumber);
		for (uint256 i = 0; i < activeBlockchains.length; i++) {
			startingSupply = startingSupply.add(
				totalSupplyAtBlockchain(activeBlockchains[i], _blockNumber)
			);
		}
		return startingSupply;
	}

	function getVotesAtBlockchain(
		bytes32 _id,
		address _user,
		uint256 _blockNumber
	) public view returns (uint256) {
		BlockchainState[] storage states = blockchainStates[_id];
		int256 i = int256(states.length);

		if (i == 0) return 0;
		BlockchainState storage state = states[uint256(i - 1)];
		for (i = i - 1; i >= 0; i--) {
			if (state.blockNumber <= _blockNumber) break;
			state = states[uint256(i - 1)];
		}
		if (i < 0) return 0;

		return stateHashBalances[state.stateHash][_user];
	}

	function totalSupplyAtBlockchain(bytes32 _id, uint256 _blockNumber)
		public
		view
		returns (uint256)
	{
		BlockchainState[] storage states = blockchainStates[_id];
		int256 i;
		if (states.length == 0) return 0;
		for (i = int256(states.length - 1); i >= 0; i--) {
			if (states[uint256(i)].blockNumber <= _blockNumber) break;
		}
		if (i < 0) return 0;

		BlockchainState storage state = states[uint256(i)];
		return state.totalSupply;
	}

	function proveBalanceOfAtBlockchain(
		string memory _id,
		address _user,
		uint256 _balance,
		bytes32[] memory _proof
	) public returns (bool) {
		bytes32 idHash = keccak256(bytes(_id));
		require(
			blockchainStates[idHash].length > 0,
			"no state found for given _id"
		);
		bytes32 stateHash =
			blockchainStates[idHash][blockchainStates[idHash].length - 1]
				.stateHash;

		//this is specifically important for rootState that should update real balance only once
		require(
			stateHashBalances[stateHash][_user] == 0,
			"stateHash already proved"
		);

		(, bool isProofValid) =
			_checkMerkleProof(_user, _balance, stateHash, _proof);
		require(isProofValid, "invalid merkle proof");

		//if initiial state then set real balance
		if (idHash == keccak256(bytes("rootState"))) {
			_mint(_user, _balance);
		}

		//if proof is valid then set balances
		stateHashBalances[stateHash][_user] = _balance;
		return true;
	}

	function delegateTo(address _delegate) public {
		return _delegateTo(msg.sender, _delegate);
	}

	function undelegate() public {
		return _delegateTo(msg.sender, msg.sender);
	}

	/**
	 * @notice Delegates votes from signatory to `delegator`
	 * @param _delegate The address to delegate votes to
	 * @param _nonce The contract state required to match the signature
	 * @param _expiry The time at which to expire the signature
	 * @param _v The recovery byte of the signature
	 * @param _r Half of the ECDSA signature pair
	 * @param _s Half of the ECDSA signature pair
	 */
	function delegateBySig(
		address _delegate,
		uint256 _nonce,
		uint256 _expiry,
		uint8 _v,
		bytes32 _r,
		bytes32 _s
	) public {
		bytes32 domainSeparator =
			keccak256(
				abi.encode(
					DOMAIN_TYPEHASH,
					keccak256(bytes(name)),
					getChainId(),
					address(this)
				)
			);
		bytes32 structHash =
			keccak256(
				abi.encode(DELEGATION_TYPEHASH, _delegate, _nonce, _expiry)
			);
		bytes32 digest =
			keccak256(
				abi.encodePacked("\x19\x01", domainSeparator, structHash)
			);
		address signatory = ecrecover(digest, _v, _r, _s);
		require(
			signatory != address(0),
			"GReputation::delegateBySig: invalid signature"
		);
		require(
			_nonce == nonces[signatory]++,
			"GReputation::delegateBySig: invalid nonce"
		);
		require(
			now <= _expiry,
			"GReputation::delegateBySig: signature expired"
		);
		return _delegateTo(signatory, _delegate);
	}

	function _delegateTo(address _user, address _delegate) internal {
		require(
			_delegate != address(0),
			"GReputation::delegate can't delegat to null address"
		);

		address curDelegator = delegates[_user];
		require(curDelegator != _delegate, "already delegating to delegator");

		delegates[_user] = _delegate;

		// remove votes from current delegator
		uint256 coreBalance = balanceOf(_user);
		//redundant check - should not be possible to have address 0 as delegator
		if (curDelegator != address(0)) {
			uint256 curVotes = getVotesAt(curDelegator, false, block.number);
			_updateDelegateVotes(
				curDelegator,
				_user,
				curVotes,
				curVotes.sub(coreBalance)
			);
		}

		//move votes to new delegator
		uint256 curVotes = getVotesAt(_delegate, false, block.number);
		_updateDelegateVotes(
			_delegate,
			_user,
			curVotes,
			curVotes.add(coreBalance)
		);
	}

	function _updateDelegateVotes(
		address _delegate,
		address _delegator,
		uint256 oldVotes,
		uint256 newVotes
	) internal {
		updateValueAtNow(activeVotes[_delegate], newVotes);
		emit DelegateVotesChanged(_delegate, _delegator, oldVotes, newVotes);
	}

	function _checkMerkleProof(
		address _user,
		uint256 _balance,
		bytes32 _root,
		bytes32[] memory _proof
	) internal pure returns (bytes32 leafHash, bool isProofValid) {
		leafHash = keccak256(abi.encode(_user, _balance));
		isProofValid = MerkleProofUpgradeable.verify(_proof, _root, leafHash);
	}

	function getChainId() internal pure returns (uint256) {
		uint256 chainId;
		assembly {
			chainId := chainid()
		}
		return chainId;
	}
}