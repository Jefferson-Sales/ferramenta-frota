// Gera o modelo da planilha do Financeiro (modelos/fechamento-frota.xlsx) usado pelo botão "Exportar fechamento".
// uso (com exceljs instalado): node ferramentas/gerar-modelo-fechamento.js modelos/fechamento-frota.xlsx
//
// Arquitetura (X1, 16/11/2026, decisões do Jefferson):
//  * aba "Base" (escondida): dados do Beep Fleet, uma linha por fato — Tipo | Hub | Filial | BU | Item | Valor.
//      DRE   = valor do hub na conta (MOURISCO já zerado e redistribuído pelo sistema; sem Manutenção)
//      PCT   = % da BU no hub (planilha de rateio importada no mês)
//      FROTA = carros por hub e locadora (média diária do mês)
//      SIS_BU = total por BU calculado pelo sistema (conferência)
//      CONC  = NF × extrato dos cartões (Ticket Log, Edenred)
//    A exportação só escreve na Base e nas linhas da aba Lançamentos; todo o resto é fórmula sobre a Base.
//  * nomes de conta, BU e filial exatamente como na planilha do Financeiro (colunas Linha DRE / Linha DRE Traduzida).
//  * abas travadas (sem senha: é proteção contra apagar fórmula sem querer); só "Observação" fica livre.
const ExcelJS = require("exceljs");
const SAIDA = process.argv[2] || "modelos/fechamento-frota.xlsx";

const LINHAS = [ // ordem da conferência (igual à planilha antiga)
  ["ALUGUEL FROTA", "Car Leasing"], ["GARAGEM", "Garage"], ["COMBUSTÍVEL FROTA", "Fuel Expenses"],
  ["LAVAGEM FROTA", "Car Wash"], ["PEDÁGIO E ESTACIONAMENTO EXTERNO", "Toll and External Parking"]];
const ORDEM_DRE = ["ALUGUEL FROTA", "LAVAGEM FROTA", "COMBUSTÍVEL FROTA", "GARAGEM", "PEDÁGIO E ESTACIONAMENTO EXTERNO"];
const FILIAIS = ["Alphaville", "Barra", "Barra Funda", "Brasília", "Campinas", "Guarulhos", "Niterói", "São Bernardo do Campo", "São Cristóvão", "Tatuapé", "Vila Olímpia"];
const HUBS = FILIAIS.map((f) => (f === "Barra" ? "Barra da Tijuca" : f));          // nomes do sistema
const BUS = ["LAB", "VACINA", "Infusões"];
const BLOCOS = [ // resumo DRE (K:Q): Linha DRE, Linha DRE Traduzida, tipo de valor
  ["Agendas", "AGENDAS", "pct"], ["Car Leasing", "ALUGUEL FROTA", "rs"], ["Car Wash", "LAVAGEM FROTA", "rs"], ["carros", "CARROS", "qtd"],
  ["Fuel Expenses", "COMBUSTÍVEL FROTA", "rs"], ["Garage", "GARAGEM", "rs"], ["Toll and External Parking", "PEDÁGIO E ESTACIONAMENTO EXTERNO", "rs"]];

const RS = '#,##0.00;[Red]-#,##0.00;"-"', PCT = "0.00%", QTD = '#,##0.0;-#,##0.0;"-"', MES = "mm/yyyy";
const VERDE = "FF008E87", VERDE_CLARO = "FFE6F7F6", CINZA = "FFF4F4F4", BRANCO = "FFFFFFFF";
const fonte = (o) => Object.assign({ name: "Arial", size: 10 }, o || {});
const B = (col) => `Base!$${col}:$${col}`;
const SUMBASE = (tipo, crit) => `SUMIFS(${B("F")},${B("A")},"${tipo}"${crit ? "," + crit : ""})`;

function titulo(ws, ref, texto, tam) { const c = ws.getCell(ref); c.value = texto; c.font = fonte({ bold: true, size: tam || 12, color: { argb: VERDE } }); }
function cab(ws, linha, colIni, textos) {
  textos.forEach((t, i) => { const c = ws.getRow(linha).getCell(colIni + i); c.value = t;
    c.font = fonte({ bold: true, color: { argb: BRANCO } }); c.fill = { type: "pattern", pattern: "solid", fgColor: { argb: VERDE } };
    c.alignment = { vertical: "middle", wrapText: true }; });
}
function f(ws, ref, formula, fmt, extra) { const c = ws.getCell(ref); c.value = { formula }; if (fmt) c.numFmt = fmt; c.font = fonte(extra); return c; }
function t(ws, ref, texto, extra) { const c = ws.getCell(ref); c.value = texto; c.font = fonte(extra); return c; }
function total(ws, ref) { const c = ws.getCell(ref); c.font = fonte({ bold: true }); c.fill = { type: "pattern", pattern: "solid", fgColor: { argb: CINZA } }; }
function statusCF(ws, ref) {
  ws.addConditionalFormatting({ ref, rules: [
    { type: "containsText", operator: "containsText", text: "Verificar", priority: 1, style: { font: { color: { argb: "FFC0392B" }, bold: true }, fill: { type: "pattern", pattern: "solid", bgColor: { argb: "FFFDECEA" } } } },
    { type: "containsText", operator: "containsText", text: "OK", priority: 2, style: { font: { color: { argb: "FF1E7B34" }, bold: true }, fill: { type: "pattern", pattern: "solid", bgColor: { argb: "FFE8F5EC" } } } }] });
}
const OBS = { type: "textLength", operator: "lessThanOrEqual", formulae: [250], allowBlank: true, showErrorMessage: true, errorTitle: "Observação", error: "Até 250 caracteres." };

async function main() {
  const wb = new ExcelJS.Workbook();
  wb.creator = "Beep Fleet"; wb.calcProperties.fullCalcOnLoad = true;

  // ------------------------------------------------------------------ Fechamento Gerencial
  const fg = wb.addWorksheet("Fechamento Gerencial", { views: [{ state: "frozen", ySplit: 4 }], properties: { tabColor: { argb: VERDE } } });
  [[1, 2], [2, 36], [3, 26], [4, 16], [5, 16], [6, 16], [7, 13], [8, 16], [9, 16], [10, 3], [11, 10], [12, 10], [13, 22], [14, 26], [15, 15], [16, 36], [17, 34]]
    .forEach(([c, w]) => { fg.getColumn(c).width = w; });
  titulo(fg, "B1", "Fechamento Gerencial – Frota", 14);
  t(fg, "B2", "Mês de referência:", { bold: true }); f(fg, "C2", "Base!$B$2", MES, { bold: true });
  t(fg, "E2", "Gerado em:"); f(fg, "F2", "Base!$B$3");
  t(fg, "H2", "Tolerância (R$):"); const tol = fg.getCell("I2"); tol.value = 1; tol.numFmt = RS; tol.font = fonte();
  tol.note = "Diferença de arredondamento aceita na conferência (centavos do rateio por hub e por BU).";
  titulo(fg, "B3", "1. Conferência por conta  (notas do mês × DRE rateada)");
  cab(fg, 4, 2, ["Conta", "Linha DRE", "Notas do mês (Lançamentos)", "DRE rateada (resumo)", "Diferença", "Status", "Notas lançadas", "Pendentes de envio"]);
  LINHAS.forEach(([trad, dre], i) => {
    const r = 5 + i;
    t(fg, `B${r}`, trad); t(fg, `C${r}`, dre);
    let notas = `SUMIFS(Lançamentos!$D:$D,Lançamentos!$H:$H,$B${r})`;
    if (trad === "COMBUSTÍVEL FROTA") notas += `-${SUMBASE("CONC", `${B("E")},"CARTAO_MANUTENCAO"`)}-${SUMBASE("CONC", `${B("E")},"CARTAO_LAVAGEM"`)}`;
    if (trad === "LAVAGEM FROTA") notas += `+${SUMBASE("CONC", `${B("E")},"CARTAO_LAVAGEM"`)}`;
    const c = f(fg, `D${r}`, notas, RS);
    if (trad === "COMBUSTÍVEL FROTA") c.note = "Notas de combustível menos o que o cartão Ticket Log pagou de lavagem (vai para Lavagem) e de pneu/óleo (vai para Manutenção, que não entra neste DRE).";
    if (trad === "LAVAGEM FROTA") c.note = "Notas de lavagem mais as lavagens pagas no cartão Ticket Log (a NF da Ticket Log é lançada como combustível).";
    f(fg, `E${r}`, `SUMIFS($O$5:$O$242,$P$5:$P$242,$B${r})`, RS);
    f(fg, `F${r}`, `D${r}-E${r}`, RS);
    f(fg, `G${r}`, `IF(ABS(F${r})<=$I$2,"OK","Verificar")`);
    f(fg, `H${r}`, `COUNTIFS(Lançamentos!$H:$H,$B${r})`, "0");
    f(fg, `I${r}`, `COUNTIFS(Lançamentos!$H:$H,$B${r},Lançamentos!$F:$F,"Pendente de envio")`, "0");
  });
  t(fg, "B10", "Total", { bold: true });
  ["D", "E", "F", "H", "I"].forEach((c) => f(fg, `${c}10`, `SUM(${c}5:${c}9)`, c >= "H" ? "0" : RS, { bold: true }));
  f(fg, "G10", `IF(ABS(F10)<=$I$2,"OK","Verificar")`, null, { bold: true });
  ["B", "C", "D", "E", "F", "G", "H", "I"].forEach((c) => total(fg, `${c}10`));
  t(fg, "B11", "DRE do Beep Fleet (5 contas, sem Manutenção)"); f(fg, "E11", SUMBASE("DRE"), RS);
  f(fg, "F11", "E10-E11", RS); f(fg, "G11", `IF(ABS(F11)<=$I$2,"OK","Verificar")`);
  statusCF(fg, "G5:G11");

  titulo(fg, "B13", "2. Faturas de cartão  (NF × extrato importado)");
  cab(fg, 14, 2, ["Item", "Ticket Log", "Edenred"]);
  const conc = (k) => SUMBASE("CONC", `${B("E")},"${k}"`);
  t(fg, "B15", "NF lançada"); f(fg, "C15", conc("TICKET_NF"), RS); f(fg, "D15", conc("EDENRED_NF"), RS);
  t(fg, "B16", "Extrato importado"); f(fg, "C16", conc("TICKET_EXTRATO"), RS); f(fg, "D16", conc("EDENRED_EXTRATO"), RS);
  t(fg, "B17", "Diferença (taxas, rateada pelo sistema)"); f(fg, "C17", "C15-C16", RS); f(fg, "D17", "D15-D16", RS);
  t(fg, "B18", "Linhas do extrato sem hub"); f(fg, "C18", conc("TICKET_SEM_HUB"), "0"); f(fg, "D18", conc("EDENRED_SEM_HUB"), "0");
  t(fg, "B19", "Lavagem no cartão (vai para Lavagem)"); f(fg, "C19", conc("CARTAO_LAVAGEM"), RS);
  t(fg, "B20", "Pneu/óleo no cartão (vai para Manutenção)"); f(fg, "C20", conc("CARTAO_MANUTENCAO"), RS);

  titulo(fg, "B21", "3. DRE por linha × unidade de negócio");
  cab(fg, 22, 2, ["Linha DRE", "", "LAB", "VACINA", "Infusões", "MATRIZ", "Total"]);
  ORDEM_DRE.forEach((linha, i) => {
    const r = 23 + i; t(fg, `B${r}`, linha);
    ["D", "E", "F", "G"].forEach((c) => f(fg, `${c}${r}`, `SUMIFS($O$5:$O$242,$P$5:$P$242,$B${r},$L$5:$L$242,${c}$22)`, RS));
    f(fg, `H${r}`, `SUM(D${r}:G${r})`, RS);
  });
  t(fg, "B28", "Total R$", { bold: true });
  ["D", "E", "F", "G", "H"].forEach((c) => { f(fg, `${c}28`, `SUM(${c}23:${c}27)`, RS, { bold: true }); total(fg, `${c}28`); }); total(fg, "B28"); total(fg, "C28");
  t(fg, "B29", "Beep Fleet (total por BU)");
  ["D", "E", "F"].forEach((c) => f(fg, `${c}29`, SUMBASE("SIS_BU", `${B("D")},${c}$22`), RS));
  f(fg, "H29", "SUM(D29:G29)", RS);
  t(fg, "B30", "Diferença"); ["D", "E", "F", "H"].forEach((c) => f(fg, `${c}30`, `${c}28-${c}29`, RS));
  t(fg, "B31", "Status"); ["D", "E", "F", "H"].forEach((c) => f(fg, `${c}31`, `IF(ABS(${c}30)<=$I$2,"OK","Verificar")`));
  f(fg, "G31", `IF(ABS(G28)<=$I$2,"OK","Verificar")`).note = "A MATRIZ (MOURISCO) não retém custo: o sistema redistribui tudo entre os hubs.";
  statusCF(fg, "D31:H31");
  t(fg, "B33", "Carros (média do mês) — quantidade, não soma em R$", { italic: true });
  ["D", "E", "F", "G"].forEach((c) => f(fg, `${c}33`, `SUMIFS($O$5:$O$242,$P$5:$P$242,"CARROS",$L$5:$L$242,${c}$22)`, "0"));
  f(fg, "H33", "SUM(D33:G33)", "0");

  titulo(fg, "K3", "4. Resumo DRE (lançamento no sistema)");
  cab(fg, 4, 11, ["Mês", "UN", "Filial", "Linha DRE", "Valor", "Linha DRE Traduzida", "Observação"]);
  let r = 5;
  BLOCOS.forEach(([dre, trad, tipo]) => {
    const linhas = [];
    FILIAIS.forEach((fl) => linhas.push(["LAB", fl])); linhas.push(["MATRIZ", "Matriz"]);
    FILIAIS.forEach((fl) => linhas.push(["VACINA", fl])); FILIAIS.forEach((fl) => linhas.push(["Infusões", fl]));
    linhas.forEach(([un, fl]) => {
      f(fg, `K${r}`, "$C$2", MES); t(fg, `L${r}`, un); t(fg, `M${r}`, fl); t(fg, `N${r}`, dre); t(fg, `P${r}`, trad);
      const pct = SUMBASE("PCT", `${B("C")},$M${r},${B("D")},$L${r}`);
      if (tipo === "rs") f(fg, `O${r}`, `${SUMBASE("DRE", `${B("C")},$M${r},${B("E")},$P${r}`)}*${pct}`, RS);
      else if (tipo === "qtd") f(fg, `O${r}`, `ROUND(${SUMBASE("FROTA", `${B("C")},$M${r}`)}*${pct},0)`, "0");
      else f(fg, `O${r}`, pct, PCT);
      const obs = fg.getCell(`Q${r}`); obs.protection = { locked: false }; obs.dataValidation = OBS; obs.font = fonte();
      if (r % 2) ["K", "L", "M", "N", "O", "P"].forEach((c) => { fg.getCell(`${c}${r}`).fill = { type: "pattern", pattern: "solid", fgColor: { argb: VERDE_CLARO } }; });
      r++;
    });
  });
  fg.getCell("O5").note = "AGENDAS = % de rateio da BU no hub (planilha de motoristas importada no mês). CARROS = média de carros do hub no mês × % da BU.";

  // ------------------------------------------------------------------ Lançamentos (notas do mês)
  const la = wb.addWorksheet("Lançamentos", { views: [{ state: "frozen", ySplit: 4 }] });
  [[1, 30], [2, 44], [3, 22], [4, 15], [5, 24], [6, 18], [7, 30], [8, 34], [9, 3], [10, 22], [11, 15], [12, 15], [13, 15], [14, 15], [15, 15], [16, 15], [17, 12]]
    .forEach(([c, w]) => { la.getColumn(c).width = w; });
  titulo(la, "A1", "Lançamentos de Notas – Frota", 14);
  t(la, "A2", "Mês de referência:", { bold: true }); f(la, "B2", "Base!$B$2", MES, { bold: true });
  t(la, "D2", "Notas do mês vindas do Beep Fleet (aprovadas, 5 contas do DRE). Só a coluna Observação é editável.", { italic: true });
  cab(la, 4, 1, ["Conta", "Fornecedor", "Filial", "Valor (R$)", "PIPE", "Status", "Observação", "Linha DRE"]);
  titulo(la, "J3", "Resumo por Filial × Linha DRE (R$)");
  cab(la, 4, 10, ["Filial", ...ORDEM_DRE, "Total", "Pendentes (qtd)"]);
  const filLanc = [...HUBS, "MOURISCO", "(sem hub)"];
  filLanc.forEach((fl, i) => {
    const rr = 5 + i; t(la, `J${rr}`, fl);
    ["K", "L", "M", "N", "O"].forEach((c) => f(la, `${c}${rr}`, `SUMIFS($D:$D,$C:$C,$J${rr},$H:$H,${c}$4)`, RS));
    f(la, `P${rr}`, `SUM(K${rr}:O${rr})`, RS);
    f(la, `Q${rr}`, `COUNTIFS($C:$C,$J${rr},$F:$F,"Pendente de envio")`, "0");
  });
  const rt = 5 + filLanc.length;
  t(la, `J${rt}`, "Total", { bold: true });
  ["K", "L", "M", "N", "O", "P", "Q"].forEach((c) => { f(la, `${c}${rt}`, `SUM(${c}5:${c}${rt - 1})`, c === "Q" ? "0" : RS, { bold: true }); total(la, `${c}${rt}`); }); total(la, `J${rt}`);
  t(la, `J${rt + 1}`, "Conferência (tabela)"); f(la, `P${rt + 1}`, `SUM($D:$D)-P${rt}`, RS);
  t(la, `J${rt + 2}`, "MOURISCO = notas da sede: o valor é redistribuído entre os hubs no Fechamento Gerencial.", { italic: true });

  // ------------------------------------------------------------------ Soma dos rateios (espelho, somente leitura)
  const sr = wb.addWorksheet("SOMA DOS RATEIOS POR BU");
  [[1, 2], [2, 24], [3, 15], [4, 14], [5, 14], [6, 14], [7, 14], [8, 14], [9, 14], [10, 14]].forEach(([c, w]) => { sr.getColumn(c).width = w; });
  titulo(sr, "B1", "Soma dos Rateios por BU", 14);
  t(sr, "B2", "Somente leitura: tudo vem do Beep Fleet. MOURISCO (sede) já vem zerado — o custo dele foi redistribuído entre os hubs.", { italic: true });
  titulo(sr, "B4", "1. % de rateio por hub  (planilha de motoristas importada no mês)");
  cab(sr, 5, 2, ["Hub", "Soma (100%)", ...BUS, "Status"]);
  HUBS.forEach((h, i) => {
    const rr = 6 + i; t(sr, `B${rr}`, h);
    ["D", "E", "F"].forEach((c) => f(sr, `${c}${rr}`, SUMBASE("PCT", `${B("B")},$B${rr},${B("D")},${c}$5`), PCT));
    f(sr, `C${rr}`, `SUM(D${rr}:F${rr})`, PCT);
    f(sr, `G${rr}`, `IF(ABS(C${rr}-1)<=0.001,"OK","Verificar")`);
  });
  statusCF(sr, "G6:G16");

  const LOC = ["ARVAL", "EVOLUTION", "LM", "LOCALIZA", "MOTOCA", "RENAULT"];
  titulo(sr, "B19", "2. Frota por hub e locadora  (média de carros por dia no mês)");
  cab(sr, 20, 2, ["Hub", "Total", ...LOC, "Outras"]);
  HUBS.forEach((h, i) => {
    const rr = 21 + i; t(sr, `B${rr}`, h);
    f(sr, `C${rr}`, SUMBASE("FROTA", `${B("B")},$B${rr}`), QTD);
    ["D", "E", "F", "G", "H", "I"].forEach((c) => f(sr, `${c}${rr}`, SUMBASE("FROTA", `${B("B")},$B${rr},${B("E")},${c}$20&"*"`), QTD));
    f(sr, `J${rr}`, `C${rr}-SUM(D${rr}:I${rr})`, QTD);
  });
  t(sr, "B32", "Total", { bold: true });
  ["C", "D", "E", "F", "G", "H", "I", "J"].forEach((c) => { f(sr, `${c}32`, `SUM(${c}21:${c}31)`, QTD, { bold: true }); total(sr, `${c}32`); }); total(sr, "B32");
  f(sr, "B33", '"Fonte: "&Base!$B$4', null, { italic: true });

  const SECOES = [["3. Combustível", "COMBUSTÍVEL FROTA"], ["4. Lavagem", "LAVAGEM FROTA"], ["5. Garagem", "GARAGEM"],
    ["6. Locação veicular", "ALUGUEL FROTA"], ["7. Pedágio / Estacionamento", "PEDÁGIO E ESTACIONAMENTO EXTERNO"], ["8. Frota — carros por BU", null]];
  let ini = 35;
  SECOES.forEach(([nome, conta]) => {
    titulo(sr, `B${ini}`, nome + (conta ? "  (valor do hub no Beep Fleet × % da BU)" : "  (média de carros × % da BU)"));
    cab(sr, ini + 1, 2, ["Hub", conta ? "Total do mês" : "Carros", ...BUS, "Conferência"]);
    HUBS.forEach((h, i) => {
      const rr = ini + 2 + i; t(sr, `B${rr}`, h);
      f(sr, `C${rr}`, conta ? SUMBASE("DRE", `${B("B")},$B${rr},${B("E")},"${conta}"`) : `C${21 + i}`, conta ? RS : QTD);
      ["D", "E", "F"].forEach((c) => f(sr, `${c}${rr}`, `$C${rr}*${c}$${6 + i}`, conta ? RS : QTD));
      f(sr, `G${rr}`, `C${rr}-SUM(D${rr}:F${rr})`, conta ? RS : QTD);
    });
    const rr = ini + 2 + HUBS.length; t(sr, `B${rr}`, "Total", { bold: true }); total(sr, `B${rr}`);
    ["C", "D", "E", "F", "G"].forEach((c) => { f(sr, `${c}${rr}`, `SUM(${c}${ini + 2}:${c}${rr - 1})`, conta ? RS : QTD, { bold: true }); total(sr, `${c}${rr}`); });
    ini = rr + 3;
  });

  // ------------------------------------------------------------------ Base (escondida; preenchida pela exportação)
  const ba = wb.addWorksheet("Base", { state: "veryHidden" });
  [[1, 12], [2, 24], [3, 22], [4, 12], [5, 36], [6, 16]].forEach(([c, w]) => { ba.getColumn(c).width = w; });
  t(ba, "A1", "Dados do Beep Fleet — gerados pela exportação. Não editar: as outras abas calculam a partir daqui.", { bold: true });
  t(ba, "A2", "Mês"); t(ba, "A3", "Gerado em"); t(ba, "A4", "Fonte da frota");
  cab(ba, 6, 1, ["Tipo", "Hub", "Filial", "BU", "Item", "Valor"]);

  for (const ws of [fg, la, sr, ba]) {
    await ws.protect("", { selectLockedCells: true, selectUnlockedCells: true, formatColumns: true, autoFilter: true, sort: false });
  }
  await wb.xlsx.writeFile(SAIDA);
  console.log("modelo gerado:", SAIDA);
}
main().catch((e) => { console.error(e); process.exit(1); });
