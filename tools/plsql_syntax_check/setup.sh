#!/usr/bin/env bash
# One-time setup of the offline PL/SQL syntax checker (Node.js 18+, git, internet to npm/GitHub).
# Usage afterwards:  npx tsx check.ts path/to/*.prc
set -euo pipefail
cd "$(dirname "$0")"
npm init -y >/dev/null
npm i antlr-ng antlr4ng tsx typescript
git clone --depth 1 --filter=blob:none --sparse https://github.com/antlr/grammars-v4.git g4
(cd g4 && git sparse-checkout set sql/plsql)
cp g4/sql/plsql/*.g4 g4/sql/plsql/Antlr4ng/* .
python3 transformGrammar.py
mkdir -p gen
npx antlr-ng -Dlanguage=TypeScript --exact-output-dir -o gen PlSqlLexer.g4 PlSqlParser.g4
cp PlSqlLexerBase.ts PlSqlParserBase.ts gen/
echo "Ready: npx tsx check.ts <files>"
