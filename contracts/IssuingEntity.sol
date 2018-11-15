pragma solidity ^0.4.24;

import "./open-zeppelin/SafeMath.sol";
import "./SecurityToken.sol";
import "./STBase.sol";
import "./interfaces/Custodian.sol";
import "./MultiSig.sol";

/// @title Issuing Entity
contract IssuingEntity is STBase, MultiSigMultiOwner {

	using SafeMath64 for uint64;
	using SafeMath for uint256;

	/*
		Each country will have discrete limits for each investor class.
		minRating corresponds to the minimum investor level for this country.
		counts[0] and levels[0] == the sum total of counts[1:] and limits[1:]
	*/
	struct Country {
		bool allowed;
		uint8 minRating;
		uint64[8] counts;
		uint64[8] limits;
	}

	struct Account {
		uint240 balance;
		uint8 rating;
		uint8 regKey;
		bool restricted;
		address registrar;
	}

	struct Token {
		bool set;
		bool restricted;
	}

	struct Registrar {
		KYCRegistrar registrar;
		bool restricted;
	}

	bool locked;
	Registrar[] regArray;
	uint64[8] public counts;
	uint64[8] public limits;
	mapping (uint16 => Country) countries;
	mapping (bytes32 => Account) accounts;
	mapping (address => Token) tokens;
	mapping (string => bytes32) documentHashes;

	event NewIssuingEntity(address creator, address contractAddr, bytes32 id);
	event TransferOwnership(
		address indexed token,
		bytes32 indexed from,
		bytes32 indexed to,
		uint256 value
	);
	event CountryModified(
		uint16 indexed country,
		bool allowed,
		uint8 minrating,
		uint64[8] limits
	);
	event InvestorLimitSet(uint16 indexed country, uint64[8] limits);
	event NewDocumentHash(string indexed document, bytes32 documentHash);
	event RegistrarAdded(address indexed registrar);
	event RegistrarRemoved(address indexed registrar);
	event CustodianAdded(address indexed custodian);
	event TokenAdded(address indexed token);
	event InvestorRestricted(bytes32 indexed id, bool restricted);
	event TokenRestricted(address indexed token, bool restricted);
	event GloballyRestricted(bool restricted);
	
	/// @dev check that call originates from a registered, unrestricted token
	modifier onlyToken() {
		require(tokens[msg.sender].set && !tokens[msg.sender].restricted);
		_;
	}

	/**
		@notice Issuing entity constructor
		@param _owners Array of addresses to associate with owner
		@param _threshold multisig threshold for owning authority
	 */
	constructor(
		address[] _owners,
		uint64 _threshold
	)
		MultiSigMultiOwner(_owners, _threshold)
		public 
	{
		regArray.push(Registrar(KYCRegistrar(0),false));
		emit NewIssuingEntity(msg.sender, address(this), ownerID);
	}

	/**
		@notice Fetch balance of an investor from their ID
		@param _id ID to query
		@return uint256 balance
	 */
	function balanceOf(bytes32 _id) external view returns (uint256) {
		return uint256(accounts[_id].balance);
	}

	/**
		@notice Fetch minrating, investor counts and limits of a country
		@dev counts[0] and levels[0] == the sum of counts[1:] and limits[1:]
		@param _country Country to query
		@return uint64 minRating, uint64 arrays of counts, limits
	 */
	function getCountry(
		uint16 _country
	)
		external
		view
		returns (uint64 _minRating, uint64[8] _count, uint64[8] _limit)
	{
		return (
			countries[_country].minRating,
			countries[_country].counts,
			countries[_country].limits
		);
	}

	/**
		@notice Set all information about a country
		@param _country Country to modify
		@param _allowed Is country approved
		@param _minRating minimum investor rating
		@param _limits array of investor limits
		@return bool success
	 */
	function setCountry(
		uint16 _country,
		bool _allowed,
		uint8 _minRating,
		uint64[8] _limits
	)
		external
		returns (bool)
	{
		if (!_checkMultiSig()) return false;
		Country storage c = countries[_country];
		c.limits = _limits;
		c.minRating = _minRating;
		c.allowed = _allowed;
		emit CountryModified(_country, _allowed, _minRating, _limits);
		return true;
	}

	/**
		@notice Initialize many countries in a single call
		@dev
			This call is useful if you have a lot of countries to approve
			where there is no investor limit specific to the investor ratings
		@param _country Array of counties to add
		@param _minRating Array of minimum investor ratings necessary for each country
		@param _limit Array of maximum mumber of investors allowed from this country
		@return bool success
	 */
	function setCountries(
		uint16[] _country,
		uint8[] _minRating,
		uint64[] _limit
	)
		external
		returns (bool)
	{
		if (!_checkMultiSig()) return false;
		require(_country.length == _minRating.length);
		require(_country.length == _limit.length);
		for (uint256 i = 0; i < _country.length; i++) {
			require(_minRating[i] != 0);
			Country storage c = countries[_country[i]];
			c.allowed = true;
			c.minRating = _minRating[i];
			c.limits[0] = _limit[i];
			emit CountryModified(_country[i], true, _minRating[i], c.limits);

		}
	}

	/**
		@notice Set investor limits
		@dev
			_limits[0] is the total investor limit, [1:] correspond to limits
			at each specific investor rating. Setting a value of 0 means there
			is no limit.
		@param _limits Array of limits
		@return bool success
	 */
	function setInvestorLimits(
		uint64[8] _limits
	)
		external
		returns (bool)
	{
		if (!_checkMultiSig()) return false;
		limits = _limits;
		emit InvestorLimitSet(0, _limits);
		return true;
	}

	/**
		@notice Check if transfer is possible based on issuer level restrictions
		@param _token address of token being transferred
		@param _auth address of the caller attempting the transfer
		@param _from address of the sender
		@param _to address of the receiver
		@param _value number of tokens being transferred
		@return bytes32 ID of caller
		@return bytes32[] IDs of sender and receiver
		@return uint8[] ratings of sender and receiver
		@return uint16[] countries of sender and receiver
	 */
	function checkTransfer(
		address _token,
		address _auth,
		address _from,
		address _to,
		uint256 _value
	)
		external
		returns (
			bytes32 _authID,
			bytes32[2] _id,
			uint8[2] _rating,
			uint16[2] _country
		)
	{
		_authID = _getID(_auth);
		_id[0] = _getID(_from);
		_id[1] = _getID(_to);
		
		if (_authID == ownerID && idMap[_auth].id != ownerID) {
			/*
				bytes4 signatures of transfer, transferFrom
				This enforces sub-authority permissioning around transfers
			*/
			require(
				authorityData[idMap[_auth].id].approvedUntil >= now &&
				authorityData[idMap[_auth].id].signatures[
					(_authID == _id[0] ? bytes4(0xa9059cbb) : bytes4(0x23b872dd))
				], "Authority is not permitted"
			);
		}

		address _addr = (_authID == _id[0] ? _auth : _from);
		bool[2] memory _allowed;

		(_allowed, _rating, _country) = _getInvestors(
			address[2]([_addr, _to]),
			uint8[2]([accounts[idMap[_addr].id].regKey, accounts[idMap[_to].id].regKey])
		);
		_checkTransfer(_token, _authID, _id, _allowed, _rating, _country, _value);
		return (_authID, _id, _rating, _country);
	}	
		
	/**
		@notice View function to check if transfer is permitted
		@param _token address of token being transferred
		@param _from address of the sender
		@param _to address of the receiver
		@param _value number of tokens being transferred
		@return bytes32[] IDs of sender and receiver
		@return uint8[] ratings of sender and receiver
		@return uint16[] countries of sender and receiver
	 */
	function checkTransferView(
		address _token,
		address _from,
		address _to,
		uint256 _value
	)
		external
		view
		returns (
			bytes32[2] _id,
			uint8[2] _rating,
			uint16[2] _country
		)
	{	
		uint8[2] memory _key;
		(_id[0], _key[0]) = _getIDView(_from);
		(_id[1], _key[1]) = _getIDView(_to);

		if (_id[0] == ownerID && idMap[_from].id != ownerID) {
			require(
				authorityData[idMap[_from].id].approvedUntil >= now &&
				authorityData[idMap[_from].id].signatures[0xa9059cbb],
				"Authority is not permitted"
			);
		}

		address[2] memory _addr = [_from, _to];
		bool[2] memory _allowed;

		(_allowed, _rating, _country) = _getInvestors(_addr, _key);
		_checkTransfer(_token, _id[0], _id, _allowed, _rating, _country, _value);
		return (_id, _rating, _country);
	}

	/**
		@dev internal check if transfer is permitted
		@param _token address of token being transferred
		@param _authID id hash of caller
		@param _id addresses of sender and receiver
		@param _allowed array of permission bools from registrar
		@param _rating array of investor ratings
		@param _country array of investor countries
		@param _value amount to be transferred
	 */
	function _checkTransfer(
		address _token,
		bytes32 _authID,
		bytes32[2] _id,
		bool[2] _allowed,
		uint8[2] _rating,
		uint16[2] _country,
		uint256 _value
	)
		internal
		view
	{	
		require(tokens[_token].set);
		/* If issuer is not the authority, check the sender is not restricted */
		if (_id[0] != ownerID) {
			require(!locked, "Transfers locked: Issuer");
			require(!tokens[_token].restricted, "Transfers locked: Token");
			require(!accounts[_id[0]].restricted, "Sender restricted: Issuer");
			require(_allowed[0], "Sender restricted: Registrar");	
		}
		/* Always check the receiver is not restricted. */
		require(!accounts[_id[1]].restricted, "Receiver restricted: Issuer");
		require(_allowed[1], "Receiver restricted: Registrar");
		if (_id[0] != _id[1]) {
			/*
				A rating of 0 implies the receiver is the issuer or a
				custodian, no further checks are needed.
			*/
			if (_rating[1] != 0) {
				Country storage c = countries[_country[1]];
				require(c.allowed, "Reciever blocked: Country");
				/*  
					If the receiving investor currently has a 0 balance,
					we must make sure a slot is available for allocation.
				*/
				require(_rating[1] >= c.minRating, "Receiver blocked: Rating");
				if (accounts[_id[1]].balance == 0) {
					/* create a bool to prevent repeated comparisons */
					bool _check = (
						_rating[0] != 0 ||
						accounts[_id[1]].balance > _value
					);
					/*
						If the sender is an investor and still retains a balance,
						a new slot must be available.
					*/
					if (_check) {
						require(
							limits[0] == 0 ||
							counts[0] < limits[0],
							"Total Investor Limit"
						);
					}
					/*
						If the investors are from different countries, make sure
						a slot is available in the overall country limit.
					*/
					if (_check || _country[0] != _country[1]) {
						require(
							c.limits[0] == 0 ||
							c.counts[0] < c.limits[0],
							"Country Investor Limit"
						);
					}
					if (!_check) {
						_check = _rating[0] != _rating[1];
					}
					/*
						If the investors are of different ratings, make sure a
						slot is available in the receiver's rating in the overall
						count.
					*/
					if (_check) {
						require(
							limits[_rating[1]] == 0 ||
							counts[_rating[1]] < limits[_rating[1]],
							"Total Investor Limit: Rating"
						);
					}
					/*
						If the investors don't match in country or rating, make
						sure a slot is available in both the specific country
						and rating for the receiver.
					*/
					if (_check || _country[0] != _country[1]) {
						require(
							c.limits[_rating[1]] == 0 ||
							c.counts[_rating[1]] < c.limits[_rating[1]],
							"Country Investor Limit: Rating"
						);
					}
				}
			}
		}
		/* Call any attached modules */
		for (uint256 i = 0; i < modules.length; i++) {
			if (address(modules[i].module) != 0 && modules[i].checkTransfer) {
				require(
					IIssuerModule(modules[i].module).checkTransfer(
						_token,
						_authID,
						_id,
						_rating,
						_country,
						_value
					)
				);
			}
		}
	}

	function getID(address _addr) external view returns (bytes32) {
		(bytes32 _id, uint8 _key) = _getIDView(_addr);
		return _id;
	}

	function _getID(address _addr) internal returns (bytes32) {
		(bytes32 _id, uint8 _key) = _getIDView(_addr);
		if (idMap[_addr].id == 0) {
			idMap[_addr].id = _id;
		}
		if (accounts[_id].regKey != _key) {
			accounts[_id].regKey = _key;
		}
		return _id;
	}

	function _getIDView(address _addr) internal view returns (bytes32, uint8) {
		if (
			authorityData[idMap[_addr].id].addressCount > 0 ||
			_addr == address(this)
		) {
			return (ownerID, 0);
		}
		bytes32 _id = idMap[_addr].id;
		if (_id == 0) {
			for (uint256 i = 1; i < regArray.length; i++) {
				if (address(regArray[i].registrar) > 0) {
					_id = regArray[i].registrar.getID(_addr);
					if (_id != 0) {
						return (_id, uint8(i));
					}
				}
			}
			revert();
		}
		if (accounts[_id].registrar != 0) {
			return (_id, 0);
		}
		if (address(regArray[accounts[_id].regKey].registrar) == 0)  {
			for (i = 1; i < regArray.length; i++) {
				if (
					address(regArray[i].registrar) != 0 && 
					_id == regArray[i].registrar.getID(_addr)
				) {
					return (_id, uint8(i));
				}
			}
			revert();
		}
		return (_id, accounts[_id].regKey);
	}

	function _getInvestors(
		address[2] _addr,
		uint8[2] _key
	)
		internal
		view
		returns (
			bool[2] _allowed,
			uint8[2] _rating,
			uint16[2] _country
		)
	{
		bytes32[2] memory _id;
		/* If key == 0 the address belongs to the issuer or a custodian. */
		if (_key[0] == 0) {
			_allowed[0] = true;
			_rating[0] = 0;
			_country[0] = 0;
		}
		if (_key[1] == 0) {
			_allowed[1] = true;
			_rating[1] = 0;
			_country[1] = 0;
		}
		
		if (_key[0] == _key[1] && _key[0] != 0) {
			(
				_id,
				_allowed,
				_rating,
				_country
			) = regArray[_key[0]].registrar.getInvestors(_addr[0], _addr[1]);
		} else {
			if (_key[0] != 0) {
				(
					_id[0],
					_allowed[0],
					_rating[0],
					_country[0]
				) = regArray[_key[0]].registrar.getInvestor(_addr[0]);
			}
			if (_key[1] != 0) {
				(
					_id[1],
					_allowed[1],
					_rating[1],
					_country[1]
				) = regArray[_key[1]].registrar.getInvestor(_addr[1]);
			}	
		}
		return (_allowed, _rating, _country);
	}

	/**
		@notice Transfer tokens through the issuing entity level
		@param _id Array of sender/receiver IDs
		@param _rating Arracy of sender/receiver ratings
		@param _country Array of sender/receiver countries
		@param _value Number of tokens being transferred
		@return boolean
	 */
	function transferTokens(
		bytes32[2] _id,
		uint8[2] _rating,
		uint16[2] _country,
		uint256 _value
	)
		external
		onlyToken
		returns (bool)
	{
		if (_id[0] == _id[1]) return true;
		uint256 _balance = uint256(accounts[_id[0]].balance).sub(_value);
		_setBalance(_id[0], _rating[0], _country[0], _balance);
		_balance = uint256(accounts[_id[1]].balance).add(_value);
		_setBalance(_id[1], _rating[1], _country[1], _balance);
		for (uint256 i = 0; i < modules.length; i++) {
			if (address(modules[i].module) != 0 && modules[i].transferTokens) {
				IIssuerModule m = IIssuerModule(modules[i].module);
				require(
					m.transferTokens(msg.sender, _id, _rating, _country, _value)
				);
			}
		}
		emit TransferOwnership(msg.sender, _id[0], _id[1], _value);
		return true;
	}

	/**
		@notice Affect a direct balance change (burn/mint) at the issuing entity level
		@param _owner Token owner
		@param _old Old balance
		@param _new New balance
		@return boolean
	 */
	function balanceChanged(
		address _owner,
		uint256 _old,
		uint256 _new
	)
		external
		onlyToken
		returns (
			bytes32 _id,
			uint8 _rating,
			uint16 _country
		)
	{
		if (_owner == address(this)) {
			_id = ownerID;
			_rating = 0;
			_country = 0;
		} else {
			bool _allowed;
			uint8 _key = accounts[idMap[_owner].id].regKey;
			(
				_id,
				_allowed,
				_rating,
				_country
			) = regArray[_key].registrar.getInvestor(_owner);
		}
		uint256 _oldTotal = accounts[_id].balance;
		if (_new > _old) {
			uint256 _newTotal = uint256(accounts[_id].balance).add(_new.sub(_old));
		} else {
			_newTotal = uint256(accounts[_id].balance).sub(_old.sub(_new));
		}
		_setBalance(_id, _rating, _country, _newTotal);
		for (uint256 i = 0; i < modules.length; i++) {
			if (address(modules[i].module) != 0 && modules[i].balanceChanged) {
				IIssuerModule m = IIssuerModule(modules[i].module);
				require(m.balanceChanged(
					msg.sender,
					_id,
					_rating,
					_country,
					_oldTotal,
					_newTotal
				));
			}
		}
		return (_id, _rating, _country);
	}

	/**
		@notice Directly set a balance at the issuing entity level
		@param _id ID of affected entity
		@param _country Country of affected entity
		@param _value New balance
		@return boolean
	 */
	function _setBalance(
		bytes32 _id,
		uint8 _rating,
		uint16 _country,
		uint256 _value
	)
		internal
	{
		Account storage a = accounts[_id];
		Country storage c = countries[_country];
		if (_id != ownerID) {
			/* rating from registrar does not match local rating */
			if (_rating != a.rating) {
				/* local rating is not 0, rating has changed */
				if (a.rating > 0) {
					c.counts[_rating] = c.counts[_rating].sub(1);
					c.counts[a.rating] = c.counts[a.rating].add(1);
				}
				a.rating = _rating;
			}
			/* If this sets an investor account balance > 0, take an available slot */
			if (a.balance == 0) {
				counts[0] = counts[0].add(1);
				counts[_rating] = counts[_rating].add(1);
				c.counts[0] = c.counts[0].add(1);
				c.counts[_rating] = c.counts[_rating].add(1);
			/* If this sets an investor account balance to 0, add another available slot */
			} else if (_value == 0) {
				counts[0] = counts[0].sub(1);
				counts[_rating] = counts[_rating].sub(1);
				c.counts[0] = c.counts[0].sub(1);
				c.counts[_rating] = c.counts[_rating].sub(1);
			}
		}
		a.balance = uint240(_value);
	}

	/**
		@notice Set document hash
		@param _documentID Document ID being hashed
		@param _hash Hash of the document
	 */
	function setDocumentHash(
		string _documentID,
		bytes32 _hash
	)
		external
		returns (bool)
	{
		if (!_checkMultiSig()) return false;
		require(documentHashes[_documentID] == 0);
		documentHashes[_documentID] = _hash;
		emit NewDocumentHash(_documentID, _hash);
		return true;
	}

	/**
		@notice Fetch document hash
		@param _documentID Document ID to fetch
		@return string
	 */
	function getDocumentHash(string _documentID) external view returns (bytes32) {
		return documentHashes[_documentID];
	}

	function setRegistrar(address _registrar, bool _allowed) external returns (bool) {
		if (!_checkMultiSig()) return false;
		for (uint256 i = 1; i < regArray.length; i++) {
			if (address(regArray[i].registrar) == _registrar) {
				regArray[i].restricted = !_allowed;
				if (_allowed) {
					emit RegistrarAdded(_registrar);
					return true;
				}
				emit RegistrarRemoved(_registrar);
				return true;
			}
		}
		if (_allowed) {
			regArray.push(Registrar(KYCRegistrar(_registrar), false));
			emit RegistrarAdded(_registrar);
			return true;
		}
		revert();
		
	}

	function getRegistrar(bytes32 _id) external view returns (address) {
		return regArray[accounts[_id].regKey].registrar;
	}

	function addCustodian(address _addr) external returns (bool) {
		if (!_checkMultiSig()) return false;
		bytes32 _id = ICustodian(_addr).id();
		idMap[_addr].id = _id;
		accounts[_id].registrar = _addr;
		emit CustodianAdded(_addr);
	}

	/**
		@notice Add a new security token contract
		@param _token Token contract address
		@return bool
	 */
	function addToken(address _token) external returns (bool) {
		if (!_checkMultiSig()) return false;
		SecurityToken token = SecurityToken(_token);
		require(!tokens[_token].set);
		require(token.ownerID() == ownerID);
		require(token.circulatingSupply() == 0);
		tokens[_token].set = true;
		uint256 _balance = uint256(accounts[ownerID].balance).add(token.treasurySupply());
		accounts[ownerID].balance = uint240(_balance);
		emit TokenAdded(_token);
		return true;
	}

	function setInvestorRestriction(
		bytes32 _id,
		bool _restricted
	)
		external
		returns (bool)
	{
		if (!_checkMultiSig()) return false;
		accounts[_id].restricted = _restricted;
		emit InvestorRestricted(_id, _restricted);
	}

	function setTokenRestriction(
		address _token,
		bool _restricted
	)
		external
		returns (bool)
	{
		if (!_checkMultiSig()) return false;
		require(tokens[_token].set);
		tokens[_token].restricted = _restricted;
		emit TokenRestricted(_token, _restricted);
		return true;
	}

	function setGlobalRestriction(bool _restricted) external returns (bool) {
		if (!_checkMultiSig()) return false;
		locked = _restricted;
		emit GloballyRestricted(_restricted);
		return true;
	}

	function attachModule(
		address _target,
		address _module
	)
		external
		returns (bool)
	{
		if (!_checkMultiSig()) return false;
		if (_target == address(this)) {
			_attachModule(_module);
		} else {
			require(tokens[_target].set);
			SecurityToken(_target).attachModule(_module);
		}
		return true;
	}

	function detachModule(
		address _target,
		address _module
	)
		external
		returns (bool)
	{
		if (_module != msg.sender) {
			if (!_checkMultiSig()) return false;
		}
		if (_target == address(this)) {
			_detachModule(_module);
		} else {
			require(tokens[_target].set);
			SecurityToken(_target).detachModule(_module);
		}
		return true;
	}

	/**
		@notice Determines if a module is active on this issuing entity
		@param _module Deployed module address
		@return boolean
	 */
	function isActiveModule(address _module) external view returns (bool) {
		return activeModules[_module];
	}

}