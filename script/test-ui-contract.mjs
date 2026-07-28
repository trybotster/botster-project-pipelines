import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import fixtures from "@trybotster/ui-contract/conformance-fixtures" with { type: "json" };
import schema from "@trybotster/ui-contract/schema" with { type: "json" };

const require = createRequire(import.meta.url);
const entrypoint = require.resolve("@trybotster/ui-contract");
const packageJson = JSON.parse(
  fs.readFileSync(path.join(path.dirname(entrypoint), "package.json"), "utf8"),
);

assert.equal(packageJson.version, "0.1.0");
assert.equal(fixtures.contract_version, "0.1.0");

const definitions = schema.$defs;
assert.deepEqual(definitions.UiActionRequest.required, [
  "request_id",
  "surface_id",
  "action_id",
  "kind",
]);
for (const field of ["node_id", "values", "payload"]) {
  assert.ok(definitions.UiActionRequest.properties[field], `request.${field} missing`);
}
for (const field of [
  "request_id",
  "surface_id",
  "action_id",
  "node_id",
  "state",
  "normalized_values",
  "presentation",
  "replacement",
]) {
  assert.ok(definitions.UiActionResult.properties[field], `result.${field} missing`);
}
assert.deepEqual(definitions.UiActionKind.enum, [
  "submit",
  "reset",
  "validate",
  "cancel",
]);
assert.ok(
  definitions.UiBindIf.oneOf.some(
    (candidate) =>
      candidate.properties?.$kind?.const === "presentation_if" &&
      candidate.properties?.predicate?.$ref === "#/$defs/UiPresentationPredicate",
  ),
);
assert.equal(fixtures.fixtures.form.props.submit_label, "Create ticket");
assert.equal(fixtures.fixtures.dialog_presence.$kind, "presentation_if");
assert.equal(fixtures.fixtures.dialog_presence.predicate.kind, "present");
assert.equal(fixtures.fixtures.dialog_presence.node.props.presentation, "auto");
assert.equal(fixtures.fixtures.selected_workspace_equality.predicate.kind, "equals");
assert.deepEqual(fixtures.fixtures.rejected.normalized_values, { title: "" });
assert.ok(fixtures.fixtures.accepted.replacement);
assert.ok(fixtures.fixtures.accepted.presentation);

const vocabulary = JSON.stringify({ schema, fixtures });
assert.equal(vocabulary.includes("tree_update"), false);
const dialogRule = definitions.UiNode.allOf.find(
  (rule) => rule.if?.properties?.type?.const === "dialog",
);
assert.deepEqual(dialogRule.then.properties.props.not.required, ["open"]);
assert.equal("open" in fixtures.fixtures.dialog_presence.node.props, false);

console.log("@trybotster/ui-contract@0.1.0 contract checks passed");
