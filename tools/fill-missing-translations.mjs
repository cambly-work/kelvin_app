#!/usr/bin/env node
import fs from "node:fs/promises";

const localizationPath = "Sources/Localization.swift";
const sourceDirectory = "Sources";
const languages = ["uk", "en", "pt"];
const targetLanguages = { uk: "uk", en: "en", pt: "pt" };
const concurrency = 8;
const repairTranslations = process.argv.includes("--repair-translations");

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
if (!repairTranslations && missing.length === 0) {
  console.log("No missing localization keys.");
  process.exit(0);
}

const placeholders = (value) =>
  value.match(/%(?:\d+\$)?(?:[-+0 #]*\d*(?:\.\d+)?)?[%@df]/g) ?? [];

const escapeSwift = (value) =>
  value.replaceAll("\\", "\\\\").replaceAll('"', '\\"').replaceAll("\n", "\\n");

const unescapeSwift = (value) => {
  try {
    return JSON.parse(`"${value}"`);
  } catch {
    return value.replaceAll("\\n", "\n").replaceAll('\\"', '"').replaceAll("\\\\", "\\");
  }
};

const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

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
    protectedText = protectedText.replace(placeholder, `__KELVIN_PH_${index}__`);
  });
  url.searchParams.set("q", protectedText);

  let response;
  for (let attempt = 1; attempt <= 4; attempt++) {
    response = await fetch(url);
    if (response.ok) break;
    if (attempt === 4 || ![429, 500, 502, 503, 504].includes(response.status)) {
      throw new Error(`${language}: HTTP ${response.status}`);
    }
    await sleep(250 * 2 ** attempt);
  }
  const body = await response.json();
  let translated = body[0].map((part) => part[0]).join("").trim();
  protectedPlaceholders.forEach((placeholder, index) => {
    translated = translated.replace(
      new RegExp(`__KELVIN_PH_\\s*${index}__`, "gi"),
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

if (repairTranslations) {
  const valuePattern = /\.(uk|en|pt)\s*:\s*"((?:\\.|[^"\\])*)"/g;
  const entries = [...localization.matchAll(entryPattern)].map((match) => {
    const key = unescapeSwift(match[1]);
    const repairs = [];
    for (const valueMatch of match[2].matchAll(valuePattern)) {
      const language = valueMatch[1];
      const value = unescapeSwift(valueMatch[2]);
      const containsCyrillic = /[А-Яа-яЁёІіЇїЄє]/u.test(value);
      const isForeignPlaceholder =
        ((language === "en" || language === "pt") && containsCyrillic) ||
        (language === "uk" && value === key && /[А-Яа-яЁё]/u.test(key));
      if (isForeignPlaceholder) repairs.push({ language, original: valueMatch[0] });
    }
    return { match, key, repairs };
  }).filter((entry) => entry.repairs.length > 0);

  const jobs = entries.flatMap((entry, entryIndex) =>
    entry.repairs.map((repair) => ({ ...repair, entryIndex, key: entry.key }))
  );
  if (jobs.length === 0) {
    console.log("No suspicious translations found.");
    process.exit(0);
  }

  let repairCursor = 0;
  async function repairWorker() {
    while (repairCursor < jobs.length) {
      const index = repairCursor++;
      const job = jobs[index];
      job.translation = await translate(job.key, job.language);
      if ((index + 1) % 25 === 0 || index + 1 === jobs.length) {
        console.log(`[${index + 1}/${jobs.length}] repaired translations`);
      }
    }
  }
  await Promise.all(Array.from({ length: concurrency }, repairWorker));

  const jobsByEntry = new Map();
  for (const job of jobs) {
    if (!jobsByEntry.has(job.entryIndex)) jobsByEntry.set(job.entryIndex, []);
    jobsByEntry.get(job.entryIndex).push(job);
  }

  const replacements = entries.map((entry, entryIndex) => {
    let replacement = entry.match[0];
    for (const job of jobsByEntry.get(entryIndex) ?? []) {
      replacement = replacement.replace(
        job.original,
        `.${job.language}: "${escapeSwift(job.translation)}"`
      );
    }
    return { start: entry.match.index, end: entry.match.index + entry.match[0].length, replacement };
  }).sort((a, b) => b.start - a.start);

  let repairedLocalization = localization;
  for (const replacement of replacements) {
    repairedLocalization =
      repairedLocalization.slice(0, replacement.start) +
      replacement.replacement +
      repairedLocalization.slice(replacement.end);
  }
  await fs.writeFile(localizationPath, repairedLocalization);
  console.log(`Repaired ${jobs.length} suspicious translations in ${entries.length} entries.`);
  process.exit(0);
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
