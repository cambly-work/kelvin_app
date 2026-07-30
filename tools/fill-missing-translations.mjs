#!/usr/bin/env node
import fs from "node:fs/promises";

const localizationPath = "Sources/Localization.swift";
const sourceDirectory = "Sources";
const languages = ["uk", "en", "pt"];
const targetLanguages = { uk: "uk", en: "en", pt: "pt" };
const concurrency = 8;

const localization = await fs.readFile(localizationPath, "utf8");
const entryPattern = /^\s*"((?:\\.|[^"\\])*)"\s*:\s*\[(.*)\]\s*,?\s*$/gm;
const table = new Set();
for (const match of localization.matchAll(entryPattern)) {
  if (languages.some((language) => match[2].includes(`.${language}`))) {
    table.add(match[1]);
  }
}

const keyPattern = /\bL\("((?:\\.|[^"\\])*)"\)/g;
const used = new Set();
for (const name of await fs.readdir(sourceDirectory)) {
  if (!name.endsWith(".swift")) continue;
  const source = await fs.readFile(`${sourceDirectory}/${name}`, "utf8");
  for (const match of source.matchAll(keyPattern)) used.add(match[1]);
}

const missing = [...used].filter((key) => !table.has(key)).sort();
if (missing.length === 0) {
  console.log("No missing localization keys.");
  process.exit(0);
}

const placeholders = (value) =>
  value.match(/%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?)?[%@df]/g) ?? [];

const escapeSwift = (value) =>
  value.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("\n", "\\n");

async function translate(text, language) {
  // Brand/technical-only labels do not benefit from machine translation.
  if (!/[А-Яа-яЁёІіЇїЄє]/u.test(text)) return text;

  const url = new URL("https://translate.googleapis.com/translate_a/single");
  url.searchParams.set("client", "gtx");
  url.searchParams.set("sl", "ru");
  url.searchParams.set("tl", targetLanguages[language]);
  url.searchParams.set("dt", "t");
  const protectedPlaceholders = placeholders(text);
  let protectedText = text;
  protectedPlaceholders.forEach((placeholder, index) => {
    protectedText = protectedText.replace(placeholder, `XPHX${index}X`);
  });
  url.searchParams.set("q", protectedText);

  const response = await fetch(url);
  if (!response.ok) throw new Error(`${language}: HTTP ${response.status}`);
  const body = await response.json();
  let translated = body[0].map((part) => part[0]).join("").trim();
  protectedPlaceholders.forEach((placeholder, index) => {
    translated = translated.replace(
      new RegExp(`XPHX\\s*${index}\\s*X`, "gi"),
      placeholder
    );
  });
  const expected = placeholders(text).sort().join("|");
  const actual = placeholders(translated).sort().join("|");
  if (expected !== actual) {
    throw new Error(`placeholder mismatch for ${JSON.stringify(text)} (${language})`);
  }
  return translated;
}

const rows = new Array(missing.length);
let cursor = 0;
async function worker() {
  while (cursor < missing.length) {
    const index = cursor++;
    const key = missing[index];
    const values = {};
    for (const language of languages) {
      values[language] = await translate(key, language);
    }
    rows[index] =
      `        "${escapeSwift(key)}": [` +
      languages
        .map((language) => `.${language}: "${escapeSwift(values[language])}"`)
        .join(", ") +
      "],";
    console.log(`[${index + 1}/${missing.length}] ${key}`);
  }
}

await Promise.all(Array.from({ length: concurrency }, worker));

const marker = "        // — Advisor Engine (Kelvin Health Center) —";
if (!localization.includes(marker)) throw new Error("Localization insertion marker not found");
const block =
  "        // — Generated missing UI coverage; review wording when product copy changes —\n" +
  rows.join("\n") +
  "\n\n";
await fs.writeFile(localizationPath, localization.replace(marker, block + marker));
console.log(`Added ${rows.length} complete localization entries.`);
