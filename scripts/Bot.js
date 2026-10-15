/* Assistant Biso : répond aux questions et annonce erreurs, refus de billet et activités.
   Version 1 : réponses à règles (fiables, gratuites). Une IA pourra être branchée plus tard
   via cfg.BOT_AI_URL (voir LISEZMOI.md). Le bot ne parle jamais de données d'un autre rôle. */
(function () {
  const Bot = { me: null, ready: false, upcoming: [], _queue: [] };
  window.Bot = Bot;

  const ICON = '<svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a8 8 0 0 1-11.6 7.1L4 20l1-4.6A8 8 0 1 1 21 12z"/></svg>';
  let panel, log, fab, dot, chipsBox;

  function role() { return Bot.me ? Bot.me.role : "visiteur"; }
  const isStaff = () => ["personnel", "proprietaire"].includes(role());
  const isOrg = () => ["organisateur", "proprietaire"].includes(role());

  /* ---------- Base de réponses ---------- */
  function upcomingText() {
    if (!Bot.upcoming.length) return "Aucun événement n'est annoncé pour le moment. Revenez bientôt !";
    return "Prochaines activités :\n" + Bot.upcoming.map((e) =>
      "• " + e.title + " : " + App.fmtDate(e.starts_at) + (e.city ? " (" + e.city + ")" : "")).join("\n") +
      "\nOuvrez la page « Événements » pour réserver.";
  }

  const RULES = [
    { re: /\b(bonjour|salut|hello|bonsoir|mambo)\b/i,
      a: () => "Bonjour ! Posez-moi votre question : paiement, billets, événements…" },
    { re: /(prochain|activit|événement|evenement|spectacle|concert|programme)/i, a: upcomingText },
    { re: /(code de transfert|j.?ai d[eé]j[aà] pay|transfert d.?argent)/i,
      a: () => "Si le paiement automatique ne fonctionne pas, envoyez le montant au numéro affiché sur la page de paiement, puis cliquez sur « J'ai déjà payé » et saisissez le code reçu par SMS. Votre billet est livré dès que le code est vérifié." },
    { re: /(payer|paiement|m-?pesa|airtel|orange|mobile money|notification)/i,
      a: () => "Pour payer : choisissez votre billet, puis votre réseau (M-Pesa, Airtel ou Orange), entrez votre numéro et validez. Vous recevrez une demande de confirmation sur votre téléphone : acceptez-la avec votre code PIN. Votre billet apparaît aussitôt dans « Mes billets »." },
    { re: /(transf[eé]r.*billet|billet.*(autre|ami|quelqu)|donner.*billet|changer.*(nom|d[eé]tenteur))/i,
      a: () => "Pour donner votre billet à quelqu'un : ouvrez « Mes billets », cliquez sur « Transférer », puis entrez le nom du nouveau détenteur. L'ancien QR code devient invalide et un nouveau est créé. Faites-le avant l'événement." },
    { re: /(perdu|retrouver|o[uù] (est|sont) mon|mes billets|re[cç]u mon billet|pas de billet)/i,
      a: () => "Vos billets se trouvent dans « Mes billets » (menu en haut). Si vous avez payé mais ne voyez rien, attendez une minute puis rechargez. Sinon, écrivez-nous avec la référence de votre paiement." },
    { re: /(rembours|annul)/i,
      a: () => "Les remboursements sont traités au cas par cas par l'équipe Biso.nabiso-Ticket. Écrivez-nous avec le nom de l'événement et la référence de votre paiement." },
    { re: /(refus|rouge|faux|invalide|d[eé]j[aà] utilis|pourquoi.*billet)/i,
      a: () => isStaff()
        ? "Sens des résultats :\n🟢 Valide : vérifiez le nom puis faites entrer.\n🔴 Déjà utilisé : le billet a déjà servi (voir l'heure).\n🔴 Faux : ce code n'existe pas.\n🟠 Autre événement : billet réel mais pour un autre événement.\n🟠 En attente : l'organisateur doit confirmer.\n🔴 Annulé ou bloqué : ne pas faire entrer."
        : "Un billet est refusé s'il a déjà été utilisé, s'il est faux, annulé ou s'il est pour un autre événement. Si vous pensez à une erreur, montrez votre pièce d'identité au personnel : il peut contacter l'organisateur." },
    { re: /(scan|scanner|qr|entr[eé]e|porte)/i,
      a: () => isStaff()
        ? "Pour scanner : choisissez votre événement, autorisez la caméra et visez le QR code. Le nom du détenteur s'affiche : comparez avec la personne, puis « Faire entrer ». Si ce n'est pas lui, appuyez sur « Ce n'est pas le détenteur »."
        : "À l'entrée, présentez le QR code de « Mes billets ». Le personnel vérifiera votre nom : gardez une pièce d'identité à portée de main." },
    { re: /(partenaire|organisateur|organiser|vendre mes billets|devenir)/i,
      a: () => "Pour vendre vos billets avec nous, ouvrez « Devenir partenaire » et envoyez votre demande. Après validation, vous aurez un espace pour suivre vos ventes et vos revenus." },
    { re: /(statistique|revenu|vendu|vente|reversement|commission)/i,
      a: () => isOrg()
        ? "Dans votre espace, ouvrez un événement puis « Statistiques » : billets vendus, entrées, revenus bruts, commission et net à recevoir."
        : "Les statistiques de vente sont réservées aux organisateurs." },
    { re: /(merci|thanks)/i, a: () => "Avec plaisir !" },
  ];

  async function answer(q) {
    for (const r of RULES) if (r.re.test(q)) return r.a();
    if (App.cfg.BOT_AI_URL) {   // branchement futur d'une IA (fonction serveur qui connaît le rôle)
      try {
        const { data: { session } } = await App.sb.auth.getSession();
        const res = await fetch(App.cfg.BOT_AI_URL, { method: "POST",
          headers: { "Content-Type": "application/json", Authorization: "Bearer " + (session ? session.access_token : "") },
          body: JSON.stringify({ question: q }) });
        const j = await res.json();
        if (j && j.answer) return j.answer;
      } catch (e) { console.error(e); }
    }
    return "Je n'ai pas bien compris. Essayez par exemple : « comment payer », « où est mon billet », « transférer un billet » ou « prochains événements ».";
  }

  /* ---------- Interface ---------- */
  function say(text, who, kind) {
    const m = document.createElement("div");
    m.className = "msg " + (who || "bot") + (kind ? " " + kind : "");
    m.textContent = text;
    log.appendChild(m);
    log.scrollTop = log.scrollHeight;
  }
  Bot.say = say;

  // Annonce proactive (erreur, refus de billet, nouvelle activité…)
  Bot.announce = function (text, kind) {
    if (!Bot.ready) { Bot._queue.push([text, kind]); return; }
    say(text, "bot", kind);
    if (!panel.classList.contains("open")) dot.classList.remove("hidden");
  };

  function open(v) {
    panel.classList.toggle("open", v);
    fab.setAttribute("aria-expanded", v);
    if (v) { dot.classList.add("hidden"); setTimeout(() => panel.querySelector("input").focus(), 50); }
  }

  function chips() {
    const list = isStaff()
      ? ["Comment scanner ?", "Pourquoi un billet est refusé ?"]
      : ["Comment payer ?", "Où est mon billet ?", "Prochains événements", "Transférer un billet"];
    chipsBox.innerHTML = "";
    list.forEach((t) => {
      const b = document.createElement("button");
      b.type = "button"; b.textContent = t;
      b.onclick = () => ask(t);
      chipsBox.appendChild(b);
    });
  }

  async function ask(q) {
    if (!q.trim()) return;
    say(q, "me");
    say(await answer(q), "bot");
  }

  async function loadUpcoming() {
    try {
      const { data } = await App.sb.from("events").select("id,title,starts_at,city")
        .eq("status", "publie").gte("starts_at", new Date().toISOString())
        .order("starts_at").limit(3);
      Bot.upcoming = data || [];
    } catch (e) { /* silencieux */ }
  }

  Bot.init = async function (me) {
    if (Bot.ready) return;
    Bot.me = me;
    fab = document.createElement("button");
    fab.className = "bot-fab"; fab.type = "button";
    fab.setAttribute("aria-label", "Ouvrir l'assistant"); fab.setAttribute("aria-expanded", "false");
    fab.innerHTML = ICON + '<span class="dot hidden"></span>';
    dot = fab.querySelector(".dot");
    panel = document.createElement("section");
    panel.className = "bot-panel"; panel.setAttribute("aria-label", "Assistant Biso");
    panel.innerHTML = `<div class="bot-head"><span>Assistant Biso</span><button type="button" aria-label="Fermer">×</button></div>
      <div class="bot-log" aria-live="polite"></div><div class="bot-chips"></div>
      <form class="bot-form"><input type="text" placeholder="Votre question…" aria-label="Votre question" autocomplete="off"><button class="btn btn-sm" type="submit">Envoyer</button></form>`;
    document.body.appendChild(panel);
    document.body.appendChild(fab);
    log = panel.querySelector(".bot-log");
    chipsBox = panel.querySelector(".bot-chips");
    fab.onclick = () => open(!panel.classList.contains("open"));
    panel.querySelector(".bot-head button").onclick = () => open(false);
    panel.querySelector("form").onsubmit = (ev) => {
      ev.preventDefault();
      const inp = ev.target.querySelector("input");
      const q = inp.value; inp.value = "";
      ask(q);
    };
    chips();
    Bot.ready = true;

    await loadUpcoming();
    const first = me && me.full_name ? me.full_name.split(" ")[0] : "";
    say("Bonjour" + (first ? " " + first : "") + " ! Je suis l'assistant Biso.nabiso-Ticket. Je réponds à vos questions et je vous préviens en cas de souci ou de nouvelle activité.");
    if (Bot.upcoming.length && !isStaff()) {
      say("Prochaine activité : " + Bot.upcoming[0].title + ", " + App.fmtDate(Bot.upcoming[0].starts_at) + ".");
      dot.classList.remove("hidden");
    }
    Bot._queue.splice(0).forEach(([t, k]) => Bot.announce(t, k));
  };
})();