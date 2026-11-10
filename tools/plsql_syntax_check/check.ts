import { CharStream, CommonTokenStream, BaseErrorListener } from 'antlr4ng';
import { PlSqlLexer } from './gen/PlSqlLexer.js';
import { PlSqlParser } from './gen/PlSqlParser.js';
import * as fs from 'fs';
class L extends BaseErrorListener { errs: string[] = []; syntaxError(_r: any, _o: any, line: number, col: number, msg: string) { this.errs.push(`${line}:${col} ${msg}`); } }
let bad = 0;
for (const f of process.argv.slice(2)) {
  let src = fs.readFileSync(f, 'utf8').replace(/\r\n/g, '\n');
  // remove SQL*Plus commands that are not SQL
  src = src.split('\n').map(l => /^\s*(show\s+err\w*|set\s+(serverout\w*|define|echo|feedback|verify|lines\w*|pages\w*|timing|head\w*|term\w*|trimspool|sqlblanklines|scan|long)\b.*|prompt\b.*|whenever\s+.*|@@?\S+)\s*$/i.test(l) ? '' : l).join('\n');
  const lexer = new PlSqlLexer(CharStream.fromString(src));
  const parser = new PlSqlParser(new CommonTokenStream(lexer));
  const l = new L(); lexer.removeErrorListeners(); parser.removeErrorListeners(); lexer.addErrorListener(l); parser.addErrorListener(l);
  parser.sql_script();
  if (l.errs.length) { bad++; console.log(`FAIL ${f}`); l.errs.slice(0, 8).forEach(e => console.log('   ' + e)); } else console.log(`OK   ${f}`);
}
process.exit(bad ? 1 : 0);
