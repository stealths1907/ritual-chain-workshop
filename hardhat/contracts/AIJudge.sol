// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PrecompileConsumer} from "./utils/PrecompileConsumer.sol";

interface IRitualWallet {
    function deposit(uint256 lockDuration) external payable;

    function depositFor(address user, uint256 lockDuration) external payable;

    function withdraw(uint256 amount) external;

    function balanceOf(address) external view returns (uint256);

    function lockUntil(address) external view returns (uint256);
}

/**
 * @title AIJudge — Privacy-Preserving Bounty System (Commit-Reveal)
 * @notice Implements a two-phase commit-reveal flow so that submissions remain
 *         hidden until the reveal window opens. Only valid, revealed answers
 *         are eligible for AI judging via Ritual's LLM precompile.
 *
 * Lifecycle:
 *   1. Owner creates a bounty with a commit deadline and a reveal deadline.
 *   2. Participants submit a commitment hash during the commit phase.
 *   3. After the commit deadline, participants reveal their answer + salt.
 *   4. After the reveal deadline, the owner triggers AI judging.
 *   5. The owner finalizes the winner and the reward is paid out.
 */
contract AIJudge is PrecompileConsumer {
    uint256 public constant MAX_SUBMISSIONS = 10;
    uint256 public constant MAX_ANSWER_LENGTH = 2_000;

    uint256 public nextBountyId = 1;

    IRitualWallet wallet =
        IRitualWallet(0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948);

    // ─── Data Structures ───────────────────────────────────────

    struct Submission {
        address submitter;
        string answer;
    }

    struct Bounty {
        address owner;
        string title;
        string rubric;
        uint256 reward;
        uint256 deadline;        // commit phase ends here
        uint256 revealDeadline;  // reveal phase ends here
        bool judged;
        bool finalized;
        bytes aiReview;
        uint256 winnerIndex;
        Submission[] submissions;
    }

    struct ConvoHistory {
        string storageType;
        string path;
        string secretsName;
    }

    // ─── Storage ───────────────────────────────────────────────

    mapping(uint256 => Bounty) public bounties;

    /// @notice commitment hash per user per bounty
    mapping(uint256 => mapping(address => bytes32)) public commitments;

    /// @notice whether a user has already revealed
    mapping(uint256 => mapping(address => bool)) public hasRevealed;

    // ─── Events ────────────────────────────────────────────────

    event BountyCreated(
        uint256 indexed bountyId,
        address indexed owner,
        string title,
        uint256 reward,
        uint256 deadline,
        uint256 revealDeadline
    );

    event CommitmentSubmitted(
        uint256 indexed bountyId,
        address indexed submitter,
        bytes32 commitment
    );

    event AnswerRevealed(
        uint256 indexed bountyId,
        uint256 indexed submissionIndex,
        address indexed submitter
    );

    event AllAnswersJudged(uint256 indexed bountyId, bytes aiReview);

    event WinnerFinalized(
        uint256 indexed bountyId,
        uint256 indexed winnerIndex,
        address indexed winner,
        uint256 reward
    );

    // ─── Modifiers ─────────────────────────────────────────────

    modifier onlyOwner(uint256 bountyId) {
        require(msg.sender == bounties[bountyId].owner, "not bounty owner");
        _;
    }

    modifier bountyExists(uint256 bountyId) {
        require(bounties[bountyId].owner != address(0), "bounty not found");
        _;
    }

    // ─── Core Functions ────────────────────────────────────────

    /**
     * @notice Create a new bounty with commit and reveal deadlines.
     * @param title       Short title describing the bounty
     * @param rubric      Judging rubric / criteria for the AI
     * @param deadline    Timestamp when the commit phase ends
     * @param revealDeadline Timestamp when the reveal phase ends (must be > deadline)
     */
    function createBounty(
        string calldata title,
        string calldata rubric,
        uint256 deadline,
        uint256 revealDeadline
    ) external payable returns (uint256 bountyId) {
        require(msg.value > 0, "reward required");
        require(deadline > block.timestamp, "deadline must be in the future");
        require(revealDeadline > deadline, "reveal must be after commit deadline");

        bountyId = nextBountyId++;

        Bounty storage bounty = bounties[bountyId];

        bounty.owner = msg.sender;
        bounty.title = title;
        bounty.rubric = rubric;
        bounty.reward = msg.value;
        bounty.deadline = deadline;
        bounty.revealDeadline = revealDeadline;
        bounty.winnerIndex = type(uint256).max;

        emit BountyCreated(bountyId, msg.sender, title, msg.value, deadline, revealDeadline);
    }

    /**
     * @notice Submit a commitment hash during the commit phase.
     *         The hash is keccak256(abi.encodePacked(answer, salt, msg.sender, bountyId)).
     * @param bountyId   The bounty to submit to
     * @param commitment The keccak256 hash of (answer, salt, msg.sender, bountyId)
     */
    function submitCommitment(
        uint256 bountyId,
        bytes32 commitment
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp <= bounty.deadline, "commit phase ended");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(commitment != bytes32(0), "empty commitment");
        require(commitments[bountyId][msg.sender] == bytes32(0), "already committed");

        commitments[bountyId][msg.sender] = commitment;

        emit CommitmentSubmitted(bountyId, msg.sender, commitment);
    }

    /**
     * @notice Reveal your answer during the reveal phase.
     *         The contract verifies that keccak256(answer, salt, msg.sender, bountyId)
     *         matches the previously submitted commitment.
     * @param bountyId The bounty to reveal for
     * @param answer   The plaintext answer
     * @param salt     The random salt used when committing
     */
    function revealAnswer(
        uint256 bountyId,
        string calldata answer,
        bytes32 salt
    ) external bountyExists(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp > bounty.deadline, "commit phase still active");
        require(block.timestamp <= bounty.revealDeadline, "reveal phase ended");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length < MAX_SUBMISSIONS, "too many submissions");
        require(bytes(answer).length <= MAX_ANSWER_LENGTH, "answer too long");

        // Must have committed
        bytes32 stored = commitments[bountyId][msg.sender];
        require(stored != bytes32(0), "no commitment found");

        // Must not have revealed already
        require(!hasRevealed[bountyId][msg.sender], "already revealed");

        // Verify hash: keccak256(answer, salt, msg.sender, bountyId) == commitment
        bytes32 computed = keccak256(
            abi.encodePacked(answer, salt, msg.sender, bountyId)
        );
        require(computed == stored, "commitment mismatch");

        // Mark as revealed and store the submission
        hasRevealed[bountyId][msg.sender] = true;
        bounty.submissions.push(
            Submission({submitter: msg.sender, answer: answer})
        );

        emit AnswerRevealed(
            bountyId,
            bounty.submissions.length - 1,
            msg.sender
        );
    }

    /**
     * @notice Trigger AI judging for all revealed answers.
     *         Can only be called after the reveal deadline.
     * @param bountyId The bounty to judge
     * @param llmInput ABI-encoded input for the LLM inference precompile
     */
    function judgeAll(
        uint256 bountyId,
        bytes calldata llmInput
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(block.timestamp > bounty.revealDeadline, "reveal phase not ended");
        require(!bounty.judged, "already judged");
        require(!bounty.finalized, "already finalized");
        require(bounty.submissions.length > 0, "no submissions");

        bytes memory output = _executePrecompile(
            LLM_INFERENCE_PRECOMPILE,
            llmInput
        );

        (
            bool hasError,
            bytes memory completionData,
            ,
            string memory errorMessage,

        ) = abi.decode(output, (bool, bytes, bytes, string, ConvoHistory));

        require(!hasError, errorMessage);

        bounty.judged = true;
        bounty.aiReview = completionData;

        emit AllAnswersJudged(bountyId, completionData);
    }

    /**
     * @notice Finalize the winner and pay out the reward.
     * @param bountyId    The bounty to finalize
     * @param winnerIndex Index of the winning submission
     */
    function finalizeWinner(
        uint256 bountyId,
        uint256 winnerIndex
    ) external bountyExists(bountyId) onlyOwner(bountyId) {
        Bounty storage bounty = bounties[bountyId];

        require(bounty.judged, "not judged yet");
        require(!bounty.finalized, "already finalized");
        require(winnerIndex < bounty.submissions.length, "invalid winner index");

        bounty.finalized = true;
        bounty.winnerIndex = winnerIndex;

        address winner = bounty.submissions[winnerIndex].submitter;
        uint256 reward = bounty.reward;
        bounty.reward = 0;

        (bool ok, ) = payable(winner).call{value: reward}("");
        require(ok, "payment failed");

        emit WinnerFinalized(bountyId, winnerIndex, winner, reward);
    }

    // ─── View Functions ────────────────────────────────────────

    function getBounty(
        uint256 bountyId
    )
        external
        view
        bountyExists(bountyId)
        returns (
            address owner,
            string memory title,
            string memory rubric,
            uint256 reward,
            uint256 deadline,
            uint256 revealDeadline,
            bool judged,
            bool finalized,
            uint256 submissionCount,
            uint256 winnerIndex,
            bytes memory aiReview
        )
    {
        Bounty storage bounty = bounties[bountyId];

        return (
            bounty.owner,
            bounty.title,
            bounty.rubric,
            bounty.reward,
            bounty.deadline,
            bounty.revealDeadline,
            bounty.judged,
            bounty.finalized,
            bounty.submissions.length,
            bounty.winnerIndex,
            bounty.aiReview
        );
    }

    /**
     * @notice Get a submission. Answers are only visible after reveal.
     */
    function getSubmission(
        uint256 bountyId,
        uint256 index
    )
        external
        view
        bountyExists(bountyId)
        returns (address submitter, string memory answer)
    {
        Bounty storage bounty = bounties[bountyId];

        require(index < bounty.submissions.length, "invalid index");

        // Answers should only be readable after reveal deadline
        require(
            block.timestamp > bounty.revealDeadline,
            "answers hidden until reveal phase ends"
        );

        Submission storage submission = bounty.submissions[index];

        return (submission.submitter, submission.answer);
    }

    /**
     * @notice Helper: compute the commitment hash off-chain or on-chain.
     */
    function computeCommitment(
        string calldata answer,
        bytes32 salt,
        address submitter,
        uint256 bountyId
    ) external pure returns (bytes32) {
        return keccak256(abi.encodePacked(answer, salt, submitter, bountyId));
    }
}
