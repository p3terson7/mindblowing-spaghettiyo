const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../..');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const source = read('app/frontend/scripts/Views/ApprovalsView.js');
const css = read('app/frontend/assets/apple-ui.css');
const hosts = Object.fromEntries(['pendingContainer', 'attentionContainer', 'approvedContainer', 'rejectedContainer'].map(id => [id, { innerHTML: '' }]));
const calls = [];
const context = {
  document: { getElementById: id => hosts[id] },
  buildApprovalCard(entry, actions) { calls.push([entry.entryId, actions]); return `<article>${entry.entryId}</article>`; },
  createEmptyState: message => `<p>${message}</p>`,
  t: key => key,
};
vm.createContext(context);
vm.runInContext(source.slice(source.indexOf('function renderApprovalsList('), source.indexOf('function applyApprovalFilters(')), context);
for (const [id, actions] of [['pendingContainer', true], ['attentionContainer', true], ['approvedContainer', false], ['rejectedContainer', false]]) {
  calls.length = 0;
  context.renderApprovalsList(id, [{ entryId: 'first' }, { entryId: 'second' }], actions);
  assert.match(hosts[id].innerHTML, /^<div class="review-card-grid">/);
  assert.deepEqual(calls, [['first', actions], ['second', actions]], 'Grid must preserve ordering and action permissions in every tab.');
  context.renderApprovalsList(id, [], actions, 'Nothing here');
  assert.equal(hosts[id].innerHTML, '<p>Nothing here</p>');
}
assert.match(css, /@container review-cards \(min-width: 680px\)[\s\S]*?repeat\(2, minmax\(0, 1fr\)\)/);
assert.match(css, /@container review-cards \(min-width: 1040px\)[\s\S]*?repeat\(3, minmax\(0, 1fr\)\)/);
assert.match(css, /\.review-tab-content\s*\{[^}]*max-height: none;[^}]*container: review-cards \/ inline-size;/);
assert.match(source, /class="review-card-duration duration-value"/);
assert.doesNotMatch(source, /setLoadingState\("(?:pending|attention|approved|rejected)Container", "queue"/);
assert(read('app/frontend/index.html').includes('assets/apple-ui.css?v=20261008-loading-performance-v1-review-cards-v1'));
assert(read('app/frontend/scripts/AppShell.js').includes('ApprovalsView.js?v=20261008-loading-performance-v1-views-20261015-v1-money-v1-review-cards-v1'));
console.log('Review grid passed: all tabs, ordering, permissions, empty states, responsive tracks, matching skeletons and asset revisions.');
