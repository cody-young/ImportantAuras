#!/usr/bin/env node
// =============================================================================
// Offline generator for Data/SpellDB.lua -- NOT loaded by the game, run this
// manually whenever you want to refresh the "Add spell" search index with
// every class/spec/hero-talent/pvp-talent spell in the game (not just spells
// the player has personally learned, which is all SpellSearch.lua's live
// C_SpellBook scan can ever see).
//
// WoW addons cannot make network requests, so this can't run in-game -- it
// hits Blizzard's official Battle.net Game Data API from your machine and
// writes a plain Lua data file that the addon loads normally.
//
// Setup (one-time):
//   1. Create a free client at https://develop.battle.net/access/clients
//   2. Note its "Client ID" and "Client Secret"
//
// Usage:
//   BNET_CLIENT_ID=xxx BNET_CLIENT_SECRET=yyy node Tools/generate_spelldb.js
//   (optional: BNET_REGION=eu, default "us"; BNET_LOCALE=en_GB, default "en_US")
//
// Requires Node 18+ (uses the global `fetch`). No npm dependencies.
//
// Schema note: the exact nested field names inside the playable-specialization
// and talent-tree API responses were not verifiable offline (Blizzard's dev
// portal docs are a JS SPA, and no live API credentials were available while
// writing this script). Rather than hardcode a guessed path like
// `talents[].spell_tooltip.spell.id`, walkForSpells() recursively scans every
// response for `{ spell: { id: <number>, name: <string> } }` sub-objects
// anywhere in the tree -- a convention Blizzard uses consistently across the
// Game Data API for spell-tooltip references. If a real run comes back with
// far fewer entries than expected, that's the place to inspect actual JSON
// output (pass --dump to print raw responses instead of parsing them).
// =============================================================================

const fs = require('fs');
const path = require('path');

const REGION = process.env.BNET_REGION || 'us';
const LOCALE = process.env.BNET_LOCALE || 'en_US';
const CLIENT_ID = process.env.BNET_CLIENT_ID;
const CLIENT_SECRET = process.env.BNET_CLIENT_SECRET;
const DUMP = process.argv.includes('--dump');

const OUT_PATH = path.join(__dirname, '..', 'Data', 'SpellDB.lua');
const REQUEST_DELAY_MS = 50;

if (!CLIENT_ID || !CLIENT_SECRET) {
    console.error(
        'Missing credentials.\n\n' +
        'Create a free client at https://develop.battle.net/access/clients\n' +
        'then run:\n\n' +
        '  BNET_CLIENT_ID=xxx BNET_CLIENT_SECRET=yyy node Tools/generate_spelldb.js\n'
    );
    process.exit(1);
}

function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

async function getAccessToken() {
    const res = await fetch(`https://${REGION}.battle.net/oauth/token`, {
        method: 'POST',
        headers: {
            'Authorization': 'Basic ' + Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString('base64'),
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'grant_type=client_credentials',
    });
    if (!res.ok) {
        throw new Error(`OAuth token request failed: ${res.status} ${await res.text()}`);
    }
    const data = await res.json();
    return data.access_token;
}

async function apiGet(token, urlPath, extraParams) {
    const url = new URL(`https://${REGION}.api.blizzard.com${urlPath}`);
    url.searchParams.set('namespace', `static-${REGION}`);
    url.searchParams.set('locale', LOCALE);
    for (const [k, v] of Object.entries(extraParams || {})) url.searchParams.set(k, v);

    await sleep(REQUEST_DELAY_MS);
    const res = await fetch(url, { headers: { Authorization: `Bearer ${token}` } });
    if (!res.ok) {
        console.warn(`  [skip] ${urlPath} -> HTTP ${res.status}`);
        return null;
    }
    const data = await res.json();
    if (DUMP) console.log(JSON.stringify(data, null, 2));
    return data;
}

// Recursively scan an arbitrary JSON value for `{ spell: { id, name } }`
// sub-objects, per the schema hedge described in the file header.
function walkForSpells(node, out) {
    if (node === null || typeof node !== 'object') return;

    if (Array.isArray(node)) {
        for (const item of node) walkForSpells(item, out);
        return;
    }

    const spell = node.spell;
    if (spell && typeof spell === 'object' && typeof spell.id === 'number' && typeof spell.name === 'string') {
        out.set(spell.id, spell.name);
    }

    for (const value of Object.values(node)) walkForSpells(value, out);
}

// Matches ".../talent-tree/{treeId}/playable-specialization/{specId}" out of
// a Game Data API `key.href`, which is the only place either id is exposed --
// `/data/wow/talent-tree/index`'s `spec_talent_trees[]` entries carry neither
// a top-level `id` nor a `playable_specialization` object, only this href, so
// matching against those fields (as an earlier version of this script did)
// always came up empty and the talent-tree fetch -- the actual source of
// `spell_tooltip.spell.{id,name}` nodes -- never ran.
const TREE_HREF_RE = /\/talent-tree\/(\d+)\/playable-specialization\/(\d+)/;

async function main() {
    console.log(`Fetching spell data for region "${REGION}"...`);
    const token = await getAccessToken();
    const found = new Map(); // id -> name

    const classIndex = await apiGet(token, '/data/wow/playable-class/index');
    if (!classIndex || !Array.isArray(classIndex.classes)) {
        throw new Error('playable-class/index did not return a classes[] array -- API shape may have changed.');
    }

    for (const klass of classIndex.classes) {
        console.log(`Class: ${klass.name} (${klass.id})`);
        const classDetail = await apiGet(token, `/data/wow/playable-class/${klass.id}`);
        if (!classDetail) continue;
        walkForSpells(classDetail, found);

        const specs = classDetail.specializations || [];
        for (const specRef of specs) {
            const specDetail = await apiGet(token, `/data/wow/playable-specialization/${specRef.id}`);
            if (specDetail) walkForSpells(specDetail, found);

            // The talent-tree/{treeId}/playable-specialization/{specId}
            // endpoint inlines class_talent_nodes, spec_talent_nodes, AND
            // hero_talent_trees (with their nodes) all in one response, so a
            // single fetch per spec covers all of it -- no separate
            // hero-talent or class-tree calls needed.
            const href = specDetail && specDetail.spec_talent_tree && specDetail.spec_talent_tree.key
                && specDetail.spec_talent_tree.key.href;
            const match = href && href.match(TREE_HREF_RE);
            if (match) {
                const [, treeId, specId] = match;
                const tree = await apiGet(token, `/data/wow/talent-tree/${treeId}/playable-specialization/${specId}`);
                if (tree) walkForSpells(tree, found);
            }
        }
    }

    if (found.size === 0) {
        console.warn(
            '\nWARNING: found 0 spells. The recursive walk found no `spell:{id,name}` ' +
            'objects in any response -- re-run with --dump on a single class to inspect ' +
            'the raw JSON shape and adjust walkForSpells() accordingly.'
        );
    }

    const entries = [...found.entries()].sort((a, b) => a[0] - b[0]);
    const lines = [
        'local addonName, ID = ...',
        '',
        '-- Generated by Tools/generate_spelldb.js -- do not hand-edit.',
        '-- Regenerate with: BNET_CLIENT_ID=... BNET_CLIENT_SECRET=... node Tools/generate_spelldb.js',
        'ID.SpellDB = {',
        ...entries.map(([id, name]) => `    { id = ${id}, name = ${luaStringLiteral(name)} },`),
        '}',
        '',
    ];

    fs.writeFileSync(OUT_PATH, lines.join('\n'));
    console.log(`\nWrote ${entries.length} spells to ${OUT_PATH}`);
}

function luaStringLiteral(s) {
    return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
