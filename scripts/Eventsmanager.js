/* Gestion des événements, catégories, lots de billets, statistiques et personnel.
   Utilisé par admin.html (owner = true) et organisateur.html (owner = false).
   La vraie sécurité est dans la base (RLS) : ce fichier ne fait qu'afficher les bons boutons. */
(function () {
  const { esc, money, $, $$ } = App;
  const sb = App.sb;
  const STATUSES = ["brouillon", "en_attente", "publie", "complet", "termine", "annule"];

  function eventFields(ev, ctx) {
    return `<label class="field"><span>Titre de l'événement</span>
        <input name="title" required maxlength="120" value="${esc(ev ? ev.title : "")}"></label>
      <div class="row">
        <label class="field"><span>Date et heure</span>
          <input type="datetime-local" name="starts_at" required value="${ev ? App.toLocalInput(ev.starts_at) : ""}"></label>
        <label class="field"><span>Capacité de la salle</span>
          <input type="number" name="capacity" min="1" required value="${ev ? ev.capacity : ""}"></label>
        <label class="field"><span>Devise des prix</span>
          <select name="currency"><option value="USD" ${ev && ev.currency === "USD" ? "selected" : ""}>USD</option>
          <option value="CDF" ${ev && ev.currency === "CDF" ? "selected" : ""}>CDF</option></select></label>
      </div>
      <div class="row">
        <label class="field"><span>Lieu (salle, stade…)</span>
          <input name="venue" value="${esc(ev ? ev.venue : "")}"></label>
        <label class="field"><span>Ville</span>
          <input name="city" value="${esc(ev ? ev.city : "")}"></label>
      </div>
      <label class="field"><span>Adresse de l'affiche (lien d'une image, facultatif)</span>
        <input type="url" name="poster_url" placeholder="https://…" value="${esc(ev ? ev.poster_url : "")}"></label>
      <label class="inline small" style="margin:12px 0">
        <input type="checkbox" name="require_ticket_photo" style="width:auto" ${ev && ev.require_ticket_photo ? "checked" : ""}>
        <span>Exiger une photo pour chaque détenteur de billet</span>
      </label>
      <label class="field"><span>Description</span>
        <textarea name="description">${esc(ev ? ev.description : "")}</textarea></label>`;
  }

  function readEvent(form) {
    const f = new FormData(form);
    return {
      title: f.get("title").trim(),
      starts_at: App.fromLocalInput(f.get("starts_at")),
      capacity: parseInt(f.get("capacity"), 10),
      currency: f.get("currency"),
      venue: f.get("venue").trim() || null,
      city: f.get("city").trim() || null,
      poster_url: f.get("poster_url").trim() || null,
      require_ticket_photo: f.get("require_ticket_photo") === "on",
      description: f.get("description").trim() || null,
    };
  }

  async function mount(root, ctx) {
    const open = new Set();
    let events = [];

    const userId = ctx.userId || (ctx.me && ctx.me.id);
    const canEdit = (ev) => ctx.owner || (
      ev.created_by === userId && ["brouillon", "en_attente"].includes(ev.status)
    );
    const lotsOf = (ev) => (ev.ticket_lots || []);
    const activeTotal = (ev) => lotsOf(ev).filter((l) => l.active).reduce((s, l) => s + l.quantity, 0);

    async function load() {
      let query = sb.from("events")
        .select("*, ticket_categories(*), ticket_lots(*)")
        .order("starts_at", { ascending: false });
      if (!ctx.owner) query = query.eq("created_by", userId);
      events = await App.q(query);
    }

    /* ---------- Affichage ---------- */
    function lotRow(ev, l) {
      const left = l.quantity - l.sold - l.held;
      const editable = canEdit(ev);
      return `<tr>
        <td>${esc(l.name)} ${l.active ? "" : '<span class="chip">désactivé</span>'}</td>
        <td>${money(l.price, ev.currency)}</td>
        <td>${l.sold} / ${l.quantity} ${left <= 0 ? '<span class="chip bad">épuisé</span>' : ""}</td>
        <td class="inline">
          ${editable ? `<button class="btn btn-ghost btn-sm" data-act="lot-edit" data-id="${esc(l.id)}">Prix / quantité</button>
          <button class="btn btn-ghost btn-sm" data-act="lot-toggle" data-id="${esc(l.id)}">${l.active ? "Désactiver" : "Activer"}</button>` : ""}
          ${ctx.operations && ctx.owner ? `<button class="btn btn-ghost btn-sm" data-act="free" data-id="${esc(l.id)}">Offrir des billets</button>` : ""}
        </td></tr>`;
    }

    function detail(ev) {
      const cats = (ev.ticket_categories || []).slice().sort((a, b) => a.sort_order - b.sort_order);
      const editable = canEdit(ev);
      const total = activeTotal(ev);
      const over = total > ev.capacity;
      return `<div class="detail" data-detail="${esc(ev.id)}">
        <hr style="border:0;border-top:1px solid var(--line);margin:16px 0">
        ${editable ? `<details class="panel"><summary>Modifier les informations</summary>
          <form data-form="edit-event" data-id="${esc(ev.id)}">${eventFields(ev, ctx)}
          <button class="btn" type="submit">Enregistrer</button></form></details>` :
          `<p class="alert warn small">L'événement est publié : seules les modifications de Biso.nabiso-Ticket sont possibles.</p>`}

        <h3>Billets</h3>
        <p class="small ${over ? "" : "muted"}">${over ? "⚠️ " : ""}Total des billets actifs : <b>${total}</b> pour une capacité de <b>${ev.capacity}</b> places.</p>
        ${cats.length ? cats.map((c) => {
          const lots = lotsOf(ev).filter((l) => l.category_id === c.id)
            .sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
          return `<div class="panel"><h3>${esc(c.name)}</h3>
            ${c.perks ? `<p class="muted small">${esc(c.perks)}</p>` : ""}
            ${lots.length ? `<div class="table-wrap"><table><thead><tr><th>Lot</th><th>Prix</th><th>Vendus</th><th></th></tr></thead>
              <tbody>${lots.map((l) => lotRow(ev, l)).join("")}</tbody></table></div>` :
              '<p class="muted small">Aucun lot dans cette catégorie.</p>'}</div>`;
        }).join("") : '<div class="empty">Ajoutez d\'abord une catégorie de places (VIP, Normal…).</div>'}

        ${editable ? `<div class="row">
          <form class="panel" data-form="add-cat" data-id="${esc(ev.id)}"><h3>Nouvelle catégorie</h3>
            <label class="field"><span>Nom (ex. VIP, Normal)</span><input name="name" required></label>
            <label class="field"><span>Avantages (facultatif)</span><input name="perks" placeholder="Place assise, boisson offerte…"></label>
            <button class="btn btn-sm" type="submit">Ajouter la catégorie</button></form>
          ${cats.length ? `<form class="panel" data-form="add-lot" data-id="${esc(ev.id)}"><h3>${ctx.owner ? "Nouveaux billets (lot)" : "Proposer un lot de billets"}</h3>
            <label class="field"><span>Catégorie</span><select name="category_id">${cats.map((c) => `<option value="${esc(c.id)}">${esc(c.name)}</option>`).join("")}</select></label>
            <label class="field"><span>Nom du lot (ex. Early bird)</span><input name="name" required value="Normal"></label>
            <div class="row"><label class="field"><span>Prix (${esc(ev.currency)})</span><input type="number" name="price" min="0" step="0.01" required></label>
            <label class="field"><span>Quantité</span><input type="number" name="quantity" min="1" required></label></div>
            <button class="btn btn-sm" type="submit">Ajouter le lot</button></form>` : ""}
        </div>` : ""}

        ${ctx.operations ? `<h3>Statistiques</h3>
          <button class="btn btn-ghost btn-sm" data-act="stats" data-id="${esc(ev.id)}">Afficher les statistiques</button>
          <div data-stats="${esc(ev.id)}" style="margin-top:12px"></div>` : ""}

        ${ctx.staff ? `<div class="panel" style="margin-top:24px">
          <h3>Affecter un scanneur à cette activité</h3>
          <p class="muted small">Le scanneur se connectera avec son compte, puis verra uniquement cette activité dans son espace de scan.</p>
          <form class="inline" data-form="add-staff" data-id="${esc(ev.id)}">
            <label class="field" style="flex:2;min-width:220px"><span>E-mail du scanneur</span>
              <input name="email" type="email" required placeholder="scanneur@example.com"></label>
            <label class="field" style="flex:1;min-width:140px"><span>Porte</span>
              <input name="gate" placeholder="Porte 1" value="Porte 1"></label>
            <button class="btn btn-sm" type="submit">Affecter le scanneur</button>
          </form>
          <p class="muted small">Le compte doit d'abord être créé et avoir le rôle « personnel » dans Supabase.</p>
          <div data-staff="${esc(ev.id)}" class="muted small">Chargement…</div>
        </div>` : ""}
      </div>`;
    }

    function card(ev) {
      const isOpen = open.has(ev.id);
      const orgName = "Biso.nabiso-Ticket";
      let actions = `<button class="btn btn-ghost btn-sm" data-act="toggle" data-id="${esc(ev.id)}">${isOpen ? "Fermer" : "Gérer les billets"}</button>`;
      if (ctx.owner) {
        actions += `<label class="inline small muted">Statut
          <select data-act="status" data-id="${esc(ev.id)}" style="width:auto">
            ${STATUSES.map((s) => `<option value="${s}" ${s === ev.status ? "selected" : ""}>${esc(App.EVENT_STATUS[s][0])}</option>`).join("")}
          </select></label>`;
      } else if (ev.status === "brouillon") {
        actions += `<button class="btn btn-sm" data-act="submit" data-id="${esc(ev.id)}">Envoyer pour validation</button>`;
      } else if (ev.status === "en_attente") {
        actions += `<button class="btn btn-ghost btn-sm" data-act="draft" data-id="${esc(ev.id)}">Repasser en brouillon</button>`;
      }
      return `<div class="panel" data-event="${esc(ev.id)}">
        <div class="inline" style="justify-content:space-between;align-items:flex-start">
          <div><h3 style="margin-bottom:2px">${esc(ev.title)}</h3>
            <div class="muted small">${esc(App.fmtDate(ev.starts_at))}${ev.venue ? " · " + esc(ev.venue) : ""}${ev.city ? ", " + esc(ev.city) : ""} · ${esc(orgName)}</div></div>
          ${App.statusChip(ev.status)}
        </div>
        <div class="inline" style="margin-top:12px">${actions}</div>
        ${isOpen ? detail(ev) : ""}
      </div>`;
    }

    function render() {
      root.innerHTML = `
        ${ctx.owner ? `<form class="panel" data-form="promote-staff">
          <h3>Ajouter un scanneur</h3>
          <p class="muted small">L'utilisateur doit avoir créé et confirmé son compte. Il pourra ensuite être affecté à une activité ci-dessous.</p>
          <div class="inline">
            <input name="email" type="email" required placeholder="E-mail de l'utilisateur" style="flex:2;min-width:240px">
            <button class="btn btn-sm" type="submit">Autoriser comme scanneur</button>
          </div>
        </form>` : ""}
        <details class="panel"><summary>＋ Créer un événement</summary>
          <form data-form="new-event">${eventFields(null, ctx)}
          <button class="btn" type="submit">Créer l'événement (brouillon)</button></form></details>
        ${events.length ? events.map(card).join("") : '<div class="empty">Aucun événement pour le moment. Créez le premier ci-dessus.</div>'}`;
      open.forEach((id) => { loadStaff(id); });
    }

    async function refresh() { await load(); render(); }

    /* ---------- Personnel ---------- */
    async function loadStaff(id) {
      const box = $(`[data-staff="${id}"]`, root);
      if (!box) return;
      try {
        const list = await App.rpc("list_staff", { p_event_id: id });
        box.innerHTML = list.length ? `<div class="table-wrap"><table><thead><tr><th>Nom</th><th>Email</th><th>Porte</th><th></th></tr></thead><tbody>
          ${list.map((s) => `<tr><td>${esc(s.full_name)}</td><td>${esc(s.email)}</td><td>${esc(s.gate)}</td>
          <td><button class="btn btn-ghost btn-sm" data-act="staff-del" data-id="${esc(s.id)}">Retirer</button></td></tr>`).join("")}
          </tbody></table></div>` : "Aucun membre du personnel affecté.";
      } catch (e) { box.textContent = App.friendly(e); }
    }

    /* ---------- Actions (clics) ---------- */
    root.addEventListener("click", async (ev) => {
      const t = ev.target.closest("[data-act]");
      if (!t || t.tagName === "SELECT") return;
      const act = t.dataset.act, id = t.dataset.id;
      await App.run(t, async () => {
        if (act === "toggle") { open.has(id) ? open.delete(id) : open.add(id); render(); }
        else if (act === "submit") {
          const e = events.find((x) => x.id === id);
          if (!lotsOf(e).some((l) => l.active)) throw new Error("Ajoutez au moins un lot de billets avant d'envoyer pour validation.");
          await App.q(sb.from("events").update({ status: "en_attente" }).eq("id", id));
          App.toast("Envoyé à Biso.nabiso-Ticket pour validation.", "ok"); await refresh();
        }
        else if (act === "draft") {
          await App.q(sb.from("events").update({ status: "brouillon" }).eq("id", id)); await refresh();
        }
        else if (act === "lot-edit") {
          const l = events.flatMap(lotsOf).find((x) => x.id === id);
          const price = prompt("Nouveau prix :", l.price); if (price === null) return;
          const qty = prompt("Nouvelle quantité totale (au moins " + (l.sold + l.held) + ") :", l.quantity); if (qty === null) return;
          await App.q(sb.from("ticket_lots").update({ price: parseFloat(price), quantity: parseInt(qty, 10) }).eq("id", id));
          await refresh();
        }
        else if (act === "lot-toggle") {
          const l = events.flatMap(lotsOf).find((x) => x.id === id);
          await App.q(sb.from("ticket_lots").update({ active: !l.active }).eq("id", id)); await refresh();
        }
        else if (act === "free") {
          const name = prompt("Nom de l'invité (sera inscrit sur le billet) :"); if (!name) return;
          const count = prompt("Combien de billets gratuits ?", "1"); if (!count) return;
          const email = prompt("Email du compte de l'invité (facultatif : sinon les billets restent dans votre compte) :") || null;
          const n = await App.rpc("issue_free_tickets", { p_lot_id: id, p_holder_name: name, p_count: parseInt(count, 10), p_guest_email: email });
          App.toast(n + " billet(s) gratuit(s) créé(s).", "ok"); await refresh();
        }
        else if (act === "stats") {
          const s = await App.rpc("org_event_stats", { p_event_id: id });
          const cur = s.currency;
          const box = $(`[data-stats="${id}"]`, root);
          box.innerHTML = `<div class="kpis">
            <div class="kpi"><b>${s.sold}</b><span>billets vendus</span></div>
            <div class="kpi"><b>${s.free}</b><span>billets gratuits</span></div>
            <div class="kpi"><b>${s.entered}</b><span>personnes entrées</span></div>
            <div class="kpi"><b>${money(s.gross, cur)}</b><span>ventes brutes</span></div>
            <div class="kpi"><b>${money(s.commission, cur)}</b><span>commission (${s.commission_percent}%)</span></div>
            <div class="kpi"><b>${money(s.net, cur)}</b><span>net pour l'organisateur</span></div>
            <div class="kpi"><b>${money(s.paid_out, cur)}</b><span>déjà reversé</span></div>
            <div class="kpi"><b>${money(s.due, cur)}</b><span>reste à reverser</span></div></div>
            ${s.by_lot.map((l) => `<div style="margin-bottom:10px"><div class="inline" style="justify-content:space-between"><span>${esc(l.category)} · ${esc(l.lot)} (${money(l.price, cur)})</span><span class="muted small">${l.sold} / ${l.quantity}</span></div>
              <div class="bar"><i style="width:${l.quantity ? Math.round((l.sold / l.quantity) * 100) : 0}%"></i></div></div>`).join("")}`;
        }
        else if (act === "staff-del") {
          await App.rpc("remove_staff", { p_assignment_id: id });
          for (const eid of open) await loadStaff(eid);
        }
      });
    });

    root.addEventListener("change", async (ev) => {
      const t = ev.target;
      if (t.dataset.act !== "status") return;
      const id = t.dataset.id, status = t.value;
      const e = events.find((x) => x.id === id);
      try {
        if (status === "publie" && !lotsOf(e).some((l) => l.active)) throw new Error("Ajoutez au moins un lot de billets avant de publier.");
        if (status === "annule" && !confirm("Annuler cet événement ? Les clients ne pourront plus acheter.")) { await refresh(); return; }
        await App.q(sb.from("events").update({ status }).eq("id", id));
        App.toast("Statut mis à jour : " + App.EVENT_STATUS[status][0], "ok");
        await refresh();
      } catch (err) { App.error(err); await refresh(); }
    });

    /* ---------- Formulaires ---------- */
    root.addEventListener("submit", async (ev) => {
      const form = ev.target.closest("[data-form]");
      if (!form) return;
      ev.preventDefault();
      const kind = form.dataset.form, id = form.dataset.id;
      const btn = form.querySelector('[type="submit"]');
      await App.run(btn, async () => {
        const f = new FormData(form);
        if (kind === "new-event") {
          const row = readEvent(form);
          row.status = "brouillon";
          const created = await App.q(sb.from("events").insert(row).select().single());
          open.add(created.id);
          App.toast("Événement créé. Ajoutez maintenant les catégories et les lots de billets.", "ok");
          await refresh();
        }
        else if (kind === "promote-staff") {
          await App.rpc("set_staff_role", { p_email: f.get("email").trim(), p_role: "personnel" });
          App.toast("Utilisateur autorisé comme scanneur.", "ok");
          form.reset();
        }
        else if (kind === "edit-event") {
          await App.q(sb.from("events").update(readEvent(form)).eq("id", id));
          App.toast("Informations enregistrées.", "ok"); await refresh();
        }
        else if (kind === "add-cat") {
          const e = events.find((x) => x.id === id);
          await App.q(sb.from("ticket_categories").insert({
            event_id: id, name: f.get("name").trim(), perks: f.get("perks").trim() || null,
            sort_order: (e.ticket_categories || []).length }));
          await refresh();
        }
        else if (kind === "add-lot") {
          const e = events.find((x) => x.id === id);
          const qty = parseInt(f.get("quantity"), 10);
          if (activeTotal(e) + qty > e.capacity &&
              !confirm("Attention : le total des billets (" + (activeTotal(e) + qty) + ") dépasse la capacité de la salle (" + e.capacity + "). Continuer quand même ?")) return;
          await App.q(sb.from("ticket_lots").insert({
            event_id: id, category_id: f.get("category_id"), name: f.get("name").trim(),
            price: parseFloat(f.get("price")), quantity: qty, active: true }));
          App.toast("Lot ajouté.", "ok"); await refresh();
        }
        else if (kind === "add-staff") {
          await App.rpc("assign_staff", { p_email: f.get("email"), p_event_id: id, p_gate: f.get("gate") || "Porte 1" });
          App.toast("Personnel affecté.", "ok"); form.reset(); await loadStaff(id);
        }
      });
    });

    await refresh();
    return { refresh };
  }

  /* Cas signalés à l'entrée : l'organisateur ou l'admin contacte le détenteur puis décide. */
  async function mountIncidents(root) {
    let last = -1;
    async function render() {
      const list = await App.rpc("list_open_incidents");
      if (last >= 0 && list.length > last && window.Bot) {
        Bot.announce("Nouveau cas signalé à l'entrée : un billet est présenté par une autre personne. Contactez le détenteur.", "error");
      }
      last = list.length;
      root.innerHTML = list.length ? list.map((i) => {
        const phone = i.holder_phone || i.buyer_phone || "";
        const d = phone.replace(/\D/g, "");
        const wa = d ? (d.startsWith("0") ? "243" + d.slice(1) : d) : "";
        return `<div class="panel"><div class="inline" style="justify-content:space-between">
          <h3 style="margin:0">${esc(i.event_title)}</h3><span class="chip warn">en attente</span></div>
          <p style="margin-top:10px">Billet au nom de <b>${esc(i.holder_name)}</b>, présenté par <b>${esc(i.present_person_name)}</b>.</p>
          <p class="muted small">Signalé par ${esc(i.reported_by_name || "le personnel")} · ${esc(App.fmtShort(i.created_at))}<br>
          Acheteur : ${esc(i.buyer_name || "")} ${esc(i.buyer_phone || "")}<br>
          Téléphone du détenteur : ${esc(i.holder_phone || "non renseigné")}</p>
          <div class="inline">
            ${phone ? `<a class="btn btn-ghost btn-sm" href="tel:${esc(phone)}">Appeler</a>
            <a class="btn btn-ghost btn-sm" target="_blank" rel="noopener" href="https://wa.me/${esc(wa)}">WhatsApp</a>` : ""}
            <button class="btn btn-ok btn-sm" data-dec="autorise" data-id="${esc(i.id)}">Le détenteur confirme : autoriser</button>
            <button class="btn btn-danger btn-sm" data-dec="refuse" data-id="${esc(i.id)}">Refuser l'entrée</button>
          </div></div>`;
      }).join("") : '<div class="empty">Aucun cas en attente.</div>';
    }
    root.addEventListener("click", async (ev) => {
      const b = ev.target.closest("[data-dec]");
      if (!b) return;
      const note = prompt("Note pour le journal (facultatif) :");
      if (note === null) return;
      await App.run(b, async () => {
        await App.rpc("decide_incident", { p_incident_id: b.dataset.id, p_decision: b.dataset.dec, p_note: note || null });
        App.toast("Décision enregistrée.", "ok");
        await render();
      });
    });
    await render();
    const iv = setInterval(() => { if (!root.isConnected) { clearInterval(iv); return; } render().catch(() => {}); }, 20000);
    return { refresh: render };
  }

  window.EventsManager = { mount, mountIncidents };
})();
