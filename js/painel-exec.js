/* Peças da Visão Executiva (Diretoria): cada função devolve HTML (texto) a
   partir de dados prontos. Não busca nada no banco. Visual em css/painel-exec.css.
   Uso: PainelExec.kpi({...}), PainelExec.barras({...}) … e depois
   PainelExec.ligar(elementoRaiz, function(destino){ ... }) para o clique
   (drill-down) e a dica ao passar o mouse.

   "ir" (destino do clique) é um objeto livre, ex.: {modulo:"frota", filtro:{status:"indisponivel"}}.
   Sem "ir", a peça não é clicável. */
(function(){
  "use strict";

  function esc(s){
    return String(s == null ? "" : s).replace(/[&<>"']/g, function(c){
      return { "&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;" }[c];
    });
  }
  function attrIr(ir){ return ir ? ' data-ir="' + esc(JSON.stringify(ir)) + '"' : ""; }
  function attrDica(d){ return d ? ' data-dica="' + esc(d) + '"' : ""; }

  // Números no padrão brasileiro. compacto: 950 / 9,4 mil / 129 mil / 4,2 mi.
  function num(n, casas){
    if (n == null || isNaN(n)) return "—";
    return Number(n).toLocaleString("pt-BR", { minimumFractionDigits: casas || 0, maximumFractionDigits: casas || 0 });
  }
  function compacto(n){
    if (n == null || isNaN(n)) return "—";
    var a = Math.abs(n);
    if (a >= 1e6) return num(n / 1e6, a >= 1e7 ? 0 : 1) + " mi";
    if (a >= 1e4) return num(n / 1e3, 0) + " mil";
    if (a >= 1e3) return num(n / 1e3, 1) + " mil";
    return num(n, 0);
  }
  function moeda(n, comp){
    if (n == null || isNaN(n)) return "—";
    return "R$ " + (comp ? compacto(n) : num(n, 2));
  }

  // Cartão de indicador.
  // o = { rot, valor, sub?, delta?:{txt, tipo:"bom"|"ruim"|"neutro"}, estado?:{txt, tipo:"alerta"|"critico"|"ok"}, ir?, dica?, semDados?: "o que falta" }
  function kpi(o){
    if (o.semDados){
      return '<div class="ex-kpi sem-dados"' + attrDica(o.dica) + '>' +
        '<span class="ex-kpi-rot">' + esc(o.rot) + '</span>' +
        '<span class="ex-kpi-valor">Sem dados</span>' +
        '<span class="ex-kpi-sub">Falta: ' + esc(o.semDados) + '</span></div>';
    }
    var tag = o.ir ? "button" : "div";
    var seta = o.delta ? (o.delta.seta || "") : "";
    return '<' + tag + (o.ir ? ' type="button"' : "") + ' class="ex-kpi"' + attrIr(o.ir) + attrDica(o.dica) + '>' +
      '<span class="ex-kpi-rot">' + esc(o.rot) + '</span>' +
      '<span class="ex-kpi-valor">' + esc(o.valor) + '</span>' +
      (o.sub ? '<span class="ex-kpi-sub">' + esc(o.sub) + '</span>' : "") +
      (o.delta ? '<span class="ex-delta ' + esc(o.delta.tipo || "neutro") + '">' + esc((seta ? seta + " " : "") + o.delta.txt) + '</span>' : "") +
      (o.estado ? '<span class="ex-estado ' + esc(o.estado.tipo) + '">' + esc(o.estado.txt) + '</span>' : "") +
      '</' + tag + '>';
  }

  function kpis(lista){ return '<div class="ex-kpis">' + lista.map(kpi).join("") + '</div>'; }

  // Aviso "Sem dados" para um gráfico inteiro.
  function vazio(titulo, falta){
    return '<div class="ex-vazio"><b>' + esc(titulo) + '</b>Sem dados. Falta: ' + esc(falta) + '</div>';
  }

  // Número principal + medidor (ex.: disponíveis × indisponíveis × outros).
  // o = { valor:"87%", rot, parte:{rot, n}, resto:{rot, n}, extras?:[{rot, n}], estado?:{txt, tipo}, ir? }
  // O preenchimento é a "parte"; resto e extras formam o trilho.
  function medidor(o){
    var extras = (o.extras || []).filter(function(e){ return e.n; });
    var total = (o.parte.n || 0) + (o.resto.n || 0) + extras.reduce(function(s, e){ return s + e.n; }, 0);
    var pct = total ? Math.round(o.parte.n / total * 1000) / 10 : 0;
    var corpo =
      '<div class="ex-destaque"><span class="ex-destaque-valor">' + esc(o.valor) + '</span><span class="ex-destaque-rot">' + esc(o.rot) + '</span></div>' +
      '<div class="ex-medidor"><div class="ex-medidor-trilho" role="img" aria-label="' + esc(o.parte.rot + ": " + o.parte.n + " de " + total) + '">' +
      '<span class="ex-medidor-ench" style="width:' + pct + '%"></span></div>' +
      '<div class="ex-medidor-leg"><span><b>' + num(o.parte.n) + '</b> ' + esc(o.parte.rot) + '</span><span><b>' + num(o.resto.n) + '</b> ' + esc(o.resto.rot) + '</span>' +
      extras.map(function(e){ return '<span><b>' + num(e.n) + '</b> ' + esc(e.rot) + '</span>'; }).join("") + '</div></div>';
    if (!o.ir) return '<div>' + corpo + '</div>';
    return '<button type="button" class="ex-kpi ex-medidor-btn"' + attrIr(o.ir) + '>' + corpo + '</button>';
  }

  // Barras horizontais. Escala única para todas as linhas (começa em zero).
  // o = { itens:[{rot, valor, valor2?, meta?, txt, txtAcima?, dica?, ir?}], legenda?:[{txt, cls:"s1"|"s2"|"meta"}], ranking?:bool, max? }
  function barras(o){
    var max = o.max || 0;
    o.itens.forEach(function(i){ max = Math.max(max, i.valor || 0, i.valor2 || 0, i.meta || 0); });
    if (!max) max = 1;
    var pct = function(v){ return Math.max(0, Math.min(100, (v || 0) / max * 100)); };
    var leg = o.legenda && o.legenda.length > 1
      ? '<div class="ex-legenda">' + o.legenda.map(function(l){ return '<span><i class="ex-amostra ' + esc(l.cls) + '"></i>' + esc(l.txt) + '</span>'; }).join("") + '</div>'
      : "";
    var linhas = o.itens.map(function(i, k){
      var dupla = i.valor2 != null;
      var tag = i.ir ? "button" : "div";
      return '<li><' + tag + (i.ir ? ' type="button"' : "") + ' class="ex-barra"' + attrIr(i.ir) + attrDica(i.dica) + '>' +
        (o.ranking ? '<span class="ex-pos">' + (k + 1) + '</span>' : "") +
        '<span class="ex-barra-rot" title="' + esc(i.rot) + '">' + esc(i.rot) + '</span>' +
        '<span class="ex-barra-pista' + (dupla ? " dupla" : "") + '">' +
          '<span class="ex-barra-ench" style="width:' + pct(i.valor) + '%"></span>' +
          (dupla ? '<span class="ex-barra-ench s2" style="width:' + pct(i.valor2) + '%"></span>' : "") +
          (i.meta != null ? '<span class="ex-barra-meta" style="left:calc(' + pct(i.meta) + '% - 1px)"></span>' : "") +
        '</span>' +
        '<span class="ex-barra-val">' + (i.txtAcima ? '<span class="acima">' + esc(i.txt) + '</span>' : esc(i.txt)) + '</span>' +
        '</' + tag + '></li>';
    }).join("");
    return leg + '<ul class="ex-barras' + (o.ranking ? " ex-ranking" : "") + '">' + linhas + '</ul>';
  }

  // Liga o clique (drill-down) e a dica de mouse/foco dentro de "raiz".
  function ligar(raiz, aoIr){
    raiz.addEventListener("click", function(ev){
      var el = ev.target.closest("[data-ir]");
      if (!el || !raiz.contains(el)) return;
      var destino; try { destino = JSON.parse(el.getAttribute("data-ir")); } catch (e) { return; }
      aoIr(destino, el);
    });
    var dica = document.createElement("div");
    dica.className = "ex-dica"; dica.hidden = true; dica.setAttribute("role", "tooltip");
    document.body.appendChild(dica);
    function mostrar(el, x, y){
      dica.textContent = el.getAttribute("data-dica");
      dica.hidden = false;
      var r = dica.getBoundingClientRect();
      var px = Math.min(x + 12, window.innerWidth - r.width - 8);
      var py = y + 16 + r.height > window.innerHeight ? y - r.height - 12 : y + 16;
      dica.style.left = Math.max(8, px) + "px"; dica.style.top = Math.max(8, py) + "px";
    }
    raiz.addEventListener("mousemove", function(ev){
      var el = ev.target.closest("[data-dica]");
      if (el && raiz.contains(el)) mostrar(el, ev.clientX, ev.clientY); else dica.hidden = true;
    });
    raiz.addEventListener("mouseleave", function(){ dica.hidden = true; });
    raiz.addEventListener("focusin", function(ev){
      var el = ev.target.closest("[data-dica]");
      if (!el) return;
      var r = el.getBoundingClientRect(); mostrar(el, r.left, r.bottom - 8);
    });
    raiz.addEventListener("focusout", function(){ dica.hidden = true; });
  }

  window.PainelExec = { esc: esc, num: num, compacto: compacto, moeda: moeda, kpi: kpi, kpis: kpis, vazio: vazio, medidor: medidor, barras: barras, ligar: ligar };
})();
