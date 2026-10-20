// ABOUTME: Unit tests for golden-vector selection in replay-check (REPLAY_ALL / REPLAY_IDS / REPLAY_GENESIS).
// ABOUTME: Pure logic — no chain or fixturenet required.
import { expect } from "chai";
import { selectVectors } from "../scripts/contract-vectors/lib/select-vectors";

const MANIFEST_IDS = ["a", "b", "c", "d"];

describe("replay-check vector selection", function () {
  // WHY: with nothing selected the harness replays the full corpus in manifest order.
  it("replays every vector when nothing is selected", function () {
    expect(selectVectors([], {}, MANIFEST_IDS)).to.deep.equal({
      ids: MANIFEST_IDS,
      genesis: false,
    });
  });

  it("replays every vector with REPLAY_ALL=1", function () {
    expect(
      selectVectors([], { REPLAY_ALL: "1" }, MANIFEST_IDS).ids,
    ).to.deep.equal(MANIFEST_IDS);
  });

  // WHY: Hardhat does not forward positional args, so REPLAY_IDS is the only way to pick
  // individual vectors; it must not silently fall through to the full corpus.
  it("replays only the ids listed in REPLAY_IDS, trimming blanks", function () {
    expect(
      selectVectors([], { REPLAY_IDS: " c, b,," }, MANIFEST_IDS),
    ).to.deep.equal({
      ids: ["c", "b"],
      genesis: false,
    });
  });

  it("combines REPLAY_IDS with REPLAY_GENESIS", function () {
    expect(
      selectVectors([], { REPLAY_IDS: "a", REPLAY_GENESIS: "1" }, MANIFEST_IDS),
    ).to.deep.equal({
      ids: ["a"],
      genesis: true,
    });
  });

  it("replays every vector with genesis when only REPLAY_GENESIS=1 is set", function () {
    expect(
      selectVectors([], { REPLAY_GENESIS: "1" }, MANIFEST_IDS),
    ).to.deep.equal({
      ids: MANIFEST_IDS,
      genesis: true,
    });
  });

  it("lets REPLAY_ALL take precedence over REPLAY_IDS", function () {
    expect(
      selectVectors([], { REPLAY_ALL: "1", REPLAY_IDS: "a" }, MANIFEST_IDS).ids,
    ).to.deep.equal(MANIFEST_IDS);
  });

  it("still accepts ids passed as positional args", function () {
    expect(selectVectors(["b", "--genesis"], {}, MANIFEST_IDS)).to.deep.equal({
      ids: ["b"],
      genesis: true,
    });
  });

  // WHY: a typo must fail loudly — replaying nothing and exiting 0 would read as a clean run.
  it("rejects ids that are not in the manifest", function () {
    expect(() =>
      selectVectors([], { REPLAY_IDS: "a,nope,also-nope" }, MANIFEST_IDS),
    ).to.throw("unknown vector id(s): nope, also-nope");
  });
});
