// Gera supabase/functions/inbound-triagem-nfs/regras-multa.js a partir do /regras.js (fonte única, com testes).
// Recorta finNorm e as seções "Triagem de multas (M1)" e "Triagem de orçamentos (O1)" e expõe globalThis.RegrasMulta. Rodar antes de publicar a função:
//   node ferramentas/gerar-regras-multa.js
const fs = require("fs"), path = require("path");
const raiz = path.join(__dirname, "..");
const src = fs.readFileSync(path.join(raiz, "regras.js"), "utf8");
const pega = (ini, fim) => {
  const a = src.indexOf(ini); if (a < 0) throw new Error("não achei: " + ini);
  const b = src.indexOf(fim, a + ini.length); if (b < 0) throw new Error("não achei o fim de: " + ini);
  return src.slice(a, b);
};
const finNorm = pega("  function finNorm(s) {", "\n  }\n") + "\n  }\n";
const multa = pega("  // ---------------------------------------------------------------- Triagem de multas (M1)", "\n  global.Regras = {");
const out = `// GERADO por ferramentas/gerar-regras-multa.js a partir de /regras.js — não editar aqui.
(function (global) {
${finNorm}${multa}
  global.RegrasMulta = { finNorm: finNorm, ehEmailDeMulta: ehEmailDeMulta, lerNotificacaoMulta: lerNotificacaoMulta, datasDaNotificacao: datasDaNotificacao,
    ehEmailDeOrcamento: ehEmailDeOrcamento, lerOrcamento: lerOrcamento, separarOrcamentos: separarOrcamentos, FILAS_TRIAGEM: FILAS_TRIAGEM };
})(globalThis);
`;
fs.writeFileSync(path.join(raiz, "supabase/functions/inbound-triagem-nfs/regras-multa.js"), out);
console.log("regras-multa.js:", out.length, "bytes");
