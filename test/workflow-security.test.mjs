import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

const workflows = [
  ".github/workflows/builder.yaml",
  ".github/workflows/pr-title.yaml",
  ".github/workflows/release.yaml",
];

test("checkout steps never persist their injected credentials", async () => {
  for (const workflow of workflows) {
    const source = await readFile(workflow, "utf8");
    const checkoutSteps = source.split("uses: actions/checkout@v7").slice(1);
    assert.ok(checkoutSteps.length > 0, workflow);
    for (const step of checkoutSteps) {
      assert.match(
        step.split("\n      - name:", 1)[0],
        /persist-credentials: false/,
        workflow,
      );
    }
  }
});

test("the release job configures push authentication explicitly", async () => {
  const source = await readFile(".github/workflows/release.yaml", "utf8");
  assert.match(source, /git -c credential\.helper=/);
  assert.doesNotMatch(source, /gh auth setup-git/);
});
