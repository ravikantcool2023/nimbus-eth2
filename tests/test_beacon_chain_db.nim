# Nimbus
# Copyright (c) 2018-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or https://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or https://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

{.used.}

import
  std/[algorithm, options, sequtils],
  unittest2,
  ../beacon_chain/[beacon_chain_db, interop, ssz],
  ../beacon_chain/spec/[beaconstate, forks, state_transition],
  ../beacon_chain/spec/datatypes/[phase0, altair],
  ../beacon_chain/consensus_object_pools/blockchain_dag,
  eth/db/kvstore,
  # test utilies
  ./testutil, ./testdbutil, ./testblockutil, ./teststateutil

when isMainModule:
  import chronicles # or some random compile error happens...

proc getPhase0StateRef(db: BeaconChainDB, root: Eth2Digest):
    phase0.NilableBeaconStateRef =
  # load beaconstate the way the block pool does it - into an existing instance
  let res = (phase0.BeaconStateRef)()
  if db.getState(root, res[], noRollback):
    return res

proc getAltairStateRef(db: BeaconChainDB, root: Eth2Digest):
    altair.NilableBeaconStateRef =
  # load beaconstate the way the block pool does it - into an existing instance
  let res = (altair.BeaconStateRef)()
  if db.getAltairState(root, res[], noRollback):
    return res

func withDigest(blck: phase0.TrustedBeaconBlock):
    phase0.TrustedSignedBeaconBlock =
  phase0.TrustedSignedBeaconBlock(
    message: blck,
    root: hash_tree_root(blck)
  )

func withDigest(blck: altair.TrustedBeaconBlock):
    altair.TrustedSignedBeaconBlock =
  altair.TrustedSignedBeaconBlock(
    message: blck,
    root: hash_tree_root(blck)
  )

suite "Beacon chain DB" & preset():
  test "empty database" & preset():
    var
      db = BeaconChainDB.new("", inMemory = true)
    check:
      db.getPhase0StateRef(Eth2Digest()).isNil
      db.getBlock(Eth2Digest()).isNone

  test "sanity check phase 0 blocks" & preset():
    var db = BeaconChainDB.new("", inMemory = true)

    let
      signedBlock = withDigest((phase0.TrustedBeaconBlock)())
      root = hash_tree_root(signedBlock.message)

    db.putBlock(signedBlock)

    check:
      db.containsBlock(root)
      db.getBlock(root).get() == signedBlock

    db.delBlock(root)
    check:
      not db.containsBlock(root)
      db.getBlock(root).isErr()

    db.putStateRoot(root, signedBlock.message.slot, root)
    var root2 = root
    root2.data[0] = root.data[0] + 1
    db.putStateRoot(root, signedBlock.message.slot + 1, root2)

    check:
      db.getStateRoot(root, signedBlock.message.slot).get() == root
      db.getStateRoot(root, signedBlock.message.slot + 1).get() == root2

    db.close()

  test "sanity check Altair blocks" & preset():
    var db = BeaconChainDB.new("", inMemory = true)

    let
      signedBlock = withDigest((altair.TrustedBeaconBlock)())
      root = hash_tree_root(signedBlock.message)

    db.putBlock(signedBlock)

    check:
      db.containsBlock(root)
      db.getAltairBlock(root).get() == signedBlock

    db.delBlock(root)
    check:
      not db.containsBlock(root)
      db.getAltairBlock(root).isErr()

    db.putStateRoot(root, signedBlock.message.slot, root)
    var root2 = root
    root2.data[0] = root.data[0] + 1
    db.putStateRoot(root, signedBlock.message.slot + 1, root2)

    check:
      db.getStateRoot(root, signedBlock.message.slot).get() == root
      db.getStateRoot(root, signedBlock.message.slot + 1).get() == root2

    db.close()

  test "sanity check phase 0 states" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})
      testStates = getTestStates(dag.headState.data)

    # Ensure transitions beyond just adding validators and increasing slots
    sort(testStates) do (x, y: ref ForkedHashedBeaconState) -> int:
      cmp($getStateRoot(x[]), $getStateRoot(y[]))

    for state in testStates:
      db.putState(state[].hbsPhase0.data)
      let root = hash_tree_root(state[])

      check:
        db.containsState(root)
        hash_tree_root(db.getPhase0StateRef(root)[]) == root

      db.delState(root)
      check:
        not db.containsState(root)
        db.getPhase0StateRef(root).isNil

    db.close()

  test "sanity check Altair states" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})
      testStates = getTestStates(dag.headState.data, true)

    # Ensure transitions beyond just adding validators and increasing slots
    sort(testStates) do (x, y: ref ForkedHashedBeaconState) -> int:
      cmp($getStateRoot(x[]), $getStateRoot(y[]))

    for state in testStates:
      db.putState(state[].hbsAltair.data)
      let root = hash_tree_root(state[])

      check:
        db.containsState(root)
        hash_tree_root(db.getAltairStateRef(root)[]) == root

      db.delState(root)
      check:
        not db.containsState(root)
        db.getAltairStateRef(root).isNil

    db.close()

  test "sanity check phase 0 states, reusing buffers" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})

    let stateBuffer = (phase0.BeaconStateRef)()
    var testStates = getTestStates(dag.headState.data)

    # Ensure transitions beyond just adding validators and increasing slots
    sort(testStates) do (x, y: ref ForkedHashedBeaconState) -> int:
      cmp($getStateRoot(x[]), $getStateRoot(y[]))

    for state in testStates:
      db.putState(state[].hbsPhase0.data)
      let root = hash_tree_root(state[])

      check:
        db.getState(root, stateBuffer[], noRollback)
        db.containsState(root)
        hash_tree_root(stateBuffer[]) == root

      db.delState(root)
      check:
        not db.containsState(root)
        not db.getState(root, stateBuffer[], noRollback)

    db.close()

  test "sanity check Altair states, reusing buffers" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})

    let stateBuffer = (altair.BeaconStateRef)()
    var testStates = getTestStates(dag.headState.data, true)

    # Ensure transitions beyond just adding validators and increasing slots
    sort(testStates) do (x, y: ref ForkedHashedBeaconState) -> int:
      cmp($getStateRoot(x[]), $getStateRoot(y[]))

    for state in testStates:
      db.putState(state[].hbsAltair.data)
      let root = hash_tree_root(state[])

      check:
        db.getAltairState(root, stateBuffer[], noRollback)
        db.containsState(root)
        hash_tree_root(stateBuffer[]) == root

      db.delState(root)
      check:
        not db.containsState(root)
        not db.getAltairState(root, stateBuffer[], noRollback)

    db.close()

  test "sanity check phase 0 getState rollback" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})
      state = (ref ForkedHashedBeaconState)(
        beaconStateFork: forkPhase0,
        hbsPhase0: phase0.HashedBeaconState(data: phase0.BeaconState(
          slot: 10.Slot)))
      root = Eth2Digest()

    db.putCorruptPhase0State(root)

    let restoreAddr = addr dag.headState

    func restore() =
      assign(state[], restoreAddr[].data)

    check:
      state[].hbsPhase0.data.slot == 10.Slot
      not db.getState(root, state[].hbsPhase0.data, restore)
      state[].hbsPhase0.data.slot != 10.Slot

  test "sanity check Altair and cross-fork getState rollback" & preset():
    var
      db = makeTestDB(SLOTS_PER_EPOCH)
      dag = init(ChainDAGRef, defaultRuntimeConfig, db, {})
      state = (ref ForkedHashedBeaconState)(
        beaconStateFork: forkAltair,
        hbsAltair: altair.HashedBeaconState(data: altair.BeaconState(
          slot: 10.Slot)))
      root = Eth2Digest()

    db.putCorruptAltairState(root)

    let restoreAddr = addr dag.headState

    func restore() =
      assign(state[], restoreAddr[].data)

    check:
      state[].hbsAltair.data.slot == 10.Slot
      not db.getAltairState(root, state[].hbsAltair.data, restore)

      # assign() has switched the case object fork
      state[].beaconStateFork == forkPhase0
      state[].hbsPhase0.data.slot != 10.Slot

  test "find ancestors" & preset():
    var
      db = BeaconChainDB.new("", inMemory = true)

    let
      a0 = withDigest(
        (phase0.TrustedBeaconBlock)(slot: GENESIS_SLOT + 0))
      a1 = withDigest(
        (phase0.TrustedBeaconBlock)(slot: GENESIS_SLOT + 1, parent_root: a0.root))
      a2 = withDigest(
        (phase0.TrustedBeaconBlock)(slot: GENESIS_SLOT + 2, parent_root: a1.root))

    doAssert toSeq(db.getAncestors(a0.root)) == []
    doAssert toSeq(db.getAncestors(a2.root)) == []

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 0
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 0

    db.putBlock(a2)

    doAssert toSeq(db.getAncestors(a0.root)) == []
    doAssert toSeq(db.getAncestors(a2.root)) == [a2]

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 0
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 1

    db.putBlock(a1)

    doAssert toSeq(db.getAncestors(a0.root)) == []
    doAssert toSeq(db.getAncestors(a2.root)) == [a2, a1]

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 0
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 2

    db.putBlock(a0)

    doAssert toSeq(db.getAncestors(a0.root)) == [a0]
    doAssert toSeq(db.getAncestors(a2.root)) == [a2, a1, a0]

    doAssert toSeq(db.getAncestorSummaries(a0.root)).len == 1
    doAssert toSeq(db.getAncestorSummaries(a2.root)).len == 3

  test "sanity check genesis roundtrip" & preset():
    # This is a really dumb way of checking that we can roundtrip a genesis
    # state. We've been bit by this because we've had a bug in the BLS
    # serialization where an all-zero default-initialized bls signature could
    # not be deserialized because the deserialization was too strict.
    var
      db = BeaconChainDB.new("", inMemory = true)

    let
      state = initialize_beacon_state_from_eth1(
        defaultRuntimeConfig, eth1BlockHash, 0,
        makeInitialDeposits(SLOTS_PER_EPOCH), {skipBlsValidation})
      root = hash_tree_root(state[])

    db.putState(state[])

    check db.containsState(root)
    let state2 = db.getPhase0StateRef(root)
    db.delState(root)
    check not db.containsState(root)
    db.close()

    check:
      hash_tree_root(state2[]) == root

  test "sanity check state diff roundtrip" & preset():
    var
      db = BeaconChainDB.new("", inMemory = true)

    # TODO htr(diff) probably not interesting/useful, but stand-in
    let
      stateDiff = BeaconStateDiff()
      root = hash_tree_root(stateDiff)

    db.putStateDiff(root, stateDiff)

    let state2 = db.getStateDiff(root)
    db.delStateDiff(root)
    check db.getStateDiff(root).isNone()
    db.close()

    check:
      hash_tree_root(state2[]) == root
