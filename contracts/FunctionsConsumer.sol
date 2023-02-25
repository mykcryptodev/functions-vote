// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "./dev/functions/FunctionsClient.sol";
// import "@chainlink/contracts/src/v0.8/dev/functions/FunctionsClient.sol"; // Once published
import "@chainlink/contracts/src/v0.8/ConfirmedOwner.sol";

/**
 * @title Functions Consumer contract
 * @notice This contract is a demonstration of using Functions.
 * @notice NOT FOR PRODUCTION USE
 */
contract FunctionsConsumer is FunctionsClient, ConfirmedOwner {
  using Functions for Functions.Request;

  bytes32 public constant DOMAIN_SEPARATOR_TYPEHASH =
    0x47e79534a245952e8b16893a336b85a3d9ea9fa8c573f3d803afb92a79469218;
  // keccak256(
  //     "EIP712Domain(uint256 chainId,address verifyingContract)"
  // );

  bytes32 public constant TRANSACTION_TYPEHASH = 0x72e9670a7ee00f5fbf1049b8c38e3f22fab7e9b85029e85cf9412f17fdd5c2ad;
  // keccak256(
  //     "Transaction(address to,uint256 value,bytes data,uint8 operation,uint256 nonce)"
  // );

  enum Operation {
    CALL,
    DELEGATECALL
  } // the operation to perform

  struct Proposal {
    bytes32[] txData; // the transaction data to execute
    uint256 txIndexToExecute; // if there are multiple transactions to execute, this is the index of the transaction to execute
  }

  // map function request ids to proposal ids
  mapping(bytes32 => string) public functionRequestsForProposals;

  // map proposal ids to tx data strings
  mapping(string => bytes32[]) public proposals;

  // map proposal ids to executed state
  mapping(string => bool) public executed;

  event OCRResponse(bytes32 indexed requestId, bytes result, bytes err);

  /**
   * @notice Executes once when a contract is created to initialize state variables
   *
   * @param oracle - The FunctionsOracle contract
   */
  constructor(address oracle) FunctionsClient(oracle) ConfirmedOwner(msg.sender) {}

  /**
   * @notice Send a simple request
   *
   * @param source JavaScript source code
   * @param secrets Encrypted secrets payload
   * @param args List of arguments accessible from within the source code
   * @param subscriptionId Billing ID
   */
  function executeRequest(
    string calldata source,
    bytes calldata secrets,
    Functions.Location secretsLocation,
    string[] calldata args,
    uint64 subscriptionId,
    uint32 gasLimit
  ) public onlyOwner returns (bytes32) {
    // make sure that the proposal that is being requested has not been executed already
    require(!executed[args[0]], "Proposal already executed");

    Functions.Request memory req;
    req.initializeRequest(Functions.Location.Inline, Functions.CodeLanguage.JavaScript, source);
    if (secrets.length > 0) {
      if (secretsLocation == Functions.Location.Inline) {
        req.addInlineSecrets(secrets);
      } else {
        req.addRemoteSecrets(secrets);
      }
    }
    if (args.length > 0) req.addArgs(args);

    bytes32 requestId = sendRequest(req, subscriptionId, gasLimit);

    // map the function request id to the proposal id
    functionRequestsForProposals[requestId] = args[0];
    return requestId;
  }

  /**
   * @notice Callback that is invoked once the DON has resolved the request or hit an error
   *
   * @param requestId The request ID, returned by sendRequest()
   * @param response Aggregated response from the user code
   * @param err Aggregated error from the user code or from the execution pipeline
   * Either response or error parameter will be set, but never both
   */
  function fulfillRequest(
    bytes32 requestId,
    bytes memory response,
    bytes memory err
  ) internal override {
    // require that the proposal has not been executed already
    require(!executed[functionRequestsForProposals[requestId]], "Proposal already executed");

    proposals[functionRequestsForProposals[requestId]] = bytesToBytes32Array(response);

    emit OCRResponse(requestId, response, err);
  }

  /// @dev Executes the transactions of a proposal via the target if accepted
  /// @param proposalId Id that should identify the proposal uniquely
  /// @param to Target of the transaction that should be executed
  /// @param value Wei value of the transaction that should be executed
  /// @param data Data of the transaction that should be executed
  /// @param operation Operation (Call or Delegatecall) of the transaction that should be executed
  /// @notice The txIndex used by this function is always `0`
  function executeProposal(
    string memory proposalId,
    address to,
    uint256 value,
    bytes memory data,
    uint8 operation
  ) public {
    executeProposalWithIndex(proposalId, to, value, data, operation, 0);
  }

  /// @dev Executes the transactions of a proposal via the target if accepted
  /// @param proposalId Id that should identify the proposal uniquely
  /// @param to Target of the transaction that should be executed
  /// @param value Wei value of the transaction that should be executed
  /// @param data Data of the transaction that should be executed
  /// @param operation Operation (Call or Delegatecall) of the transaction that should be executed
  /// @param txIndex Index of the transaction hash in txHashes. This is used as the nonce for the transaction, to make the tx hash unique
  function executeProposalWithIndex(
    string memory proposalId,
    address to,
    uint256 value,
    bytes memory data,
    uint8 operation,
    uint256 txIndex
  ) public {
    // check if the proposal has been executed yet or not
    require(!executed[proposalId], "Proposal already executed");
    // mark the proposal as executed
    executed[proposalId] = true;

    // check if the transaction data matches the proposal
    require(keccak256(abi.encode(to, value, data, operation)) == proposals[proposalId][txIndex], "Tx hash mismatch");
    // string(to, value, data, operation, txIndex);
    require(
      exec(to, value, data, operation == 0 ? Operation.CALL : Operation.DELEGATECALL),
      "Module transaction failed"
    );
  }

  function exec(
    address to,
    uint256 value,
    bytes memory data,
    Operation operation
  ) private returns (bool) {
    bool success;
    bytes memory returnData;
    // execute the transaction
    if (operation == Operation.CALL) {
      // solhint-disable-next-line avoid-low-level-calls
      (success, returnData) = to.call{value: value}(data);
      return success;
    } else if (operation == Operation.DELEGATECALL) {
      // solhint-disable-next-line avoid-low-level-calls
      (success, returnData) = to.delegatecall(data);
      return success;
    }
    // check if the transaction was successful
    if (!success) {
      // Check if the transaction failed silently (without revert message)
      if (returnData.length == 0) {
        revert("Transaction reverted silently");
      } else {
        // Bubble up the original error
        // solhint-disable-next-line no-inline-assembly
        assembly {
          let returnData_size := mload(returnData)
          revert(add(32, returnData), returnData_size)
        }
      }
    }
    return true;
  }

  /// @dev Generates the data for the module transaction hash (required for signing)
  function generateTransactionHashData(
    address to,
    uint256 value,
    bytes memory data,
    Operation operation,
    uint256 nonce
  ) public view returns (bytes memory) {
    uint256 chainId = getChainId();
    bytes32 domainSeparator = keccak256(abi.encode(DOMAIN_SEPARATOR_TYPEHASH, chainId, this));
    bytes32 transactionHash = keccak256(abi.encode(TRANSACTION_TYPEHASH, to, value, keccak256(data), operation, nonce));
    return abi.encodePacked(bytes1(0x19), bytes1(0x01), domainSeparator, transactionHash);
  }

  function getTransactionHash(
    address to,
    uint256 value,
    bytes memory data,
    Operation operation,
    uint256 nonce
  ) public view returns (bytes32) {
    return keccak256(generateTransactionHashData(to, value, data, operation, nonce));
  }

  /// @dev Returns the chain id used by this contract.
  function getChainId() public view returns (uint256) {
    uint256 id;
    // solium-disable-next-line security/no-inline-assembly
    assembly {
      id := chainid()
    }
    return id;
  }

  function decodeTx(bytes memory data)
    internal
    pure
    returns (
      address to,
      uint256 value,
      bytes memory txData,
      uint8 operation
    )
  {
    (to, value, txData, operation) = abi.decode(data, (address, uint256, bytes, uint8));
  }

  function bytes32ToString(bytes32 _bytes32) public pure returns (string memory) {
    uint8 i = 0;
    while (i < 32 && _bytes32[i] != 0) {
      i++;
    }
    bytes memory bytesArray = new bytes(i);
    for (i = 0; i < 32 && _bytes32[i] != 0; i++) {
      bytesArray[i] = _bytes32[i];
    }
    return string(bytesArray);
  }

  function bytesToBytes32Array(bytes memory data) public pure returns (bytes32[] memory) {
    // Find 32 bytes segments nb
    uint256 dataNb = data.length / 32;
    // Create an array of dataNb elements
    bytes32[] memory dataList = new bytes32[](dataNb);
    // Start array index at 0
    uint256 index = 0;
    // Loop all 32 bytes segments
    for (uint256 i = 32; i <= data.length; i = i + 32) {
      bytes32 temp;
      // Get 32 bytes from data
      // solium-disable-next-line security/no-inline-assembly
      assembly {
        temp := mload(add(data, i))
      }
      // Add extracted 32 bytes to list
      dataList[index] = temp;
      index++;
    }
    // Return data list
    return (dataList);
  }

  function hasCompletelyExecuted(string memory proposalId) public view returns (bool) {
    // if the length of the proposalId's txData is equal to the txIndexToExecute (+1), then the proposal has been executed
    return executed[proposalId];
  }

  /**
   * @notice Allows the Functions oracle address to be updated
   *
   * @param oracle New oracle address
   */
  function updateOracleAddress(address oracle) public onlyOwner {
    setOracle(oracle);
  }

  function addSimulatedRequestId(address oracleAddress, bytes32 requestId) public onlyOwner {
    addExternalRequest(oracleAddress, requestId);
  }

  // allow to receive eth
  receive() external payable {}
}
