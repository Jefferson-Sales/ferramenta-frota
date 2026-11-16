// Exportar fechamento (X1): preenche o modelo modelos/fechamento-frota.xlsx com os dados do Beep Fleet.
// Só escreve na aba "Base" (escondida) e nas linhas da aba "Lançamentos"; o resto do modelo é fórmula.
// Funciona no navegador (window.FechamentoExport) e no Node (testes), recebendo um Workbook do ExcelJS já carregado.
(function (global) {
  var RS = '#,##0.00;[Red]-#,##0.00;"-"';
  var OBS = { type: "textLength", operator: "lessThanOrEqual", formulae: [250], allowBlank: true, showErrorMessage: true, errorTitle: "Observação", error: "Até 250 caracteres." };
  var PROTECAO = { selectLockedCells: true, selectUnlockedCells: true, formatColumns: true, autoFilter: true, sort: false };

  // r = Regras.baseFechamento(dados); info = { geradoEm: "16/11/2026 14:30 por Fulano", frotaFonte: "..." }
  function preencher(wb, r, info) {
    var base = wb.getWorksheet("Base"), lanc = wb.getWorksheet("Lançamentos");
    if (!base || !lanc) throw new Error("Modelo sem as abas Base e Lançamentos.");
    var p = String(r.mes || "").split("-");
    base.getCell("B2").value = new Date(Date.UTC(Number(p[0]), Number(p[1]) - 1, 1));
    base.getCell("B2").numFmt = "mm/yyyy";
    base.getCell("B3").value = (info && info.geradoEm) || "";
    base.getCell("B4").value = (info && info.frotaFonte) || "";
    r.base.forEach(function (l, i) {
      var row = base.getRow(7 + i);
      for (var c = 0; c < 6; c++) row.getCell(c + 1).value = l[c] == null ? null : l[c];
    });
    var fonte = { name: "Arial", size: 10 };
    r.notas.forEach(function (n, i) {
      var row = lanc.getRow(5 + i);
      [n.conta, n.fornecedor, n.filial, n.valor, n.pipe, n.status, null, n.linha].forEach(function (v, c) {
        var cel = row.getCell(c + 1); cel.value = v; cel.font = fonte;
      });
      row.getCell(4).numFmt = RS;
      var obs = row.getCell(7); obs.protection = { locked: false }; obs.dataValidation = OBS;
    });
    lanc.autoFilter = "A4:H" + Math.max(5, 4 + r.notas.length);
    wb.calcProperties = wb.calcProperties || {};
    wb.calcProperties.fullCalcOnLoad = true;      // o Excel recalcula tudo ao abrir
    base.state = "veryHidden";
    var travas = wb.worksheets.map(function (ws) { return ws.protect("", PROTECAO); });
    return Promise.all(travas).then(function () { return wb; });
  }
  function nomeArquivo(mes) { return "Fechamento-Frota-" + mes + ".xlsx"; }

  var api = { preencher: preencher, nomeArquivo: nomeArquivo };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  global.FechamentoExport = api;
})(typeof window !== "undefined" ? window : globalThis);
