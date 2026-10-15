/* Catalogue public des événements publiés. */
(function () {
  const EventCatalog = {};
  window.EventCatalog = EventCatalog;

  const text = (value) => String(value || "").trim();

  function availableLots(event) {
    return (event.ticket_categories || []).flatMap((category) =>
      (category.ticket_lots || []).filter((lot) =>
        lot.active && lot.quantity > (lot.sold || 0) + (lot.held || 0)
      )
    );
  }

  function card(event) {
    const date = App.dayParts(event.starts_at);
    const lots = availableLots(event);
    const configuredLots = (event.ticket_categories || []).some((category) =>
      (category.ticket_lots || []).length > 0
    );
    const prices = lots.map((lot) => Number(lot.price)).filter(Number.isFinite);
    const price = prices.length ? Math.min(...prices) : null;
    const completed = event.status === "complet" || (configuredLots && price === null);
    let posterUrl = "";
    if (event.poster_url) {
      try {
        const parsed = new URL(event.poster_url, location.href);
        if (parsed.protocol === "https:" || parsed.protocol === "http:") posterUrl = parsed.href;
      } catch (error) {
        console.warn("URL d'affiche invalide pour l'événement", event.id);
      }
    }
    const place = [event.venue, event.city].filter(Boolean).map(App.esc).join(" · ");
    return `<article class="stub" aria-label="${App.esc(event.title)}">
      <div class="stub-poster">
        ${posterUrl ? `<img src="${App.esc(posterUrl)}" alt="" loading="lazy">` : ""}
        <div class="stub-date"><b>${date.day}</b><span>${App.esc(date.mon)}</span></div>
      </div>
      <div class="stub-body">
        <div class="inline" style="justify-content:space-between;align-items:flex-start">
          <h3>${App.esc(event.title)}</h3>${App.statusChip(event.status)}
        </div>
        <p class="muted small">${App.esc(App.fmtDate(event.starts_at))}</p>
        ${place ? `<p class="muted small">${place}</p>` : ""}
        ${event.description ? `<p>${App.esc(event.description)}</p>` : ""}
      </div>
      <div class="stub-foot">
        <span class="price">${price !== null ? "Dès " + App.money(price, event.currency) :
          completed ? "Complet" : "Tarifs à venir"}</span>
        <a class="btn btn-sm" href="evenement.html?id=${encodeURIComponent(event.id)}" aria-label="Voir ${App.esc(event.title)}">
          ${completed ? "Détails" : price === null ? "Découvrir" : "Choisir"}
        </a>
      </div>
    </article>`;
  }

  function withinDate(dateValue, filter) {
    if (filter === "all") return true;
    const start = new Date();
    start.setHours(0, 0, 0, 0);
    const date = new Date(dateValue);
    const days = filter === "today" ? 1 : filter === "week" ? 7 : 30;
    const end = new Date(start);
    end.setDate(end.getDate() + days);
    return date >= start && date < end;
  }

  EventCatalog.init = async function () {
    const list = document.getElementById("event-list");
    const count = document.getElementById("event-count");
    const search = document.getElementById("event-search");
    const city = document.getElementById("event-city");
    const date = document.getElementById("event-date");
    if (!list || !count || !search || !city || !date) return;
    if (!App.sb) {
      list.innerHTML = '<div class="empty">Le catalogue est indisponible : vérifiez la connexion à la base de données.</div>';
      count.textContent = "";
      return;
    }

    try {
      const events = await App.q(App.sb.from("events")
        .select("id,title,description,starts_at,venue,city,poster_url,currency,status,ticket_categories(name,ticket_lots(name,price,quantity,sold,held,active))")
        .in("status", ["publie", "complet"])
        .gte("starts_at", new Date().toISOString())
        .order("starts_at", { ascending: true })
        .limit(500));

      const cities = [...new Set(events.map((event) => text(event.city)).filter(Boolean))]
        .sort((a, b) => a.localeCompare(b, "fr"));
      city.innerHTML = '<option value="">Toutes les villes</option>' +
        cities.map((name) => `<option value="${App.esc(name)}">${App.esc(name)}</option>`).join("");

      function render() {
        const query = text(search.value).toLocaleLowerCase("fr");
        const selectedCity = city.value;
        const selectedDate = date.value;
        const filtered = events.filter((event) => {
          const searchable = [event.title, event.description, event.city, event.venue]
            .map(text).join(" ").toLocaleLowerCase("fr");
          return (!query || searchable.includes(query)) &&
            (!selectedCity || event.city === selectedCity) &&
            withinDate(event.starts_at, selectedDate);
        });

        count.textContent = `${filtered.length} événement${filtered.length === 1 ? "" : "s"}`;
        list.innerHTML = filtered.length
          ? filtered.map(card).join("")
          : '<div class="empty">Aucun événement ne correspond à votre recherche.</div>';
      }

      search.addEventListener("input", render);
      city.addEventListener("change", render);
      date.addEventListener("change", render);
      render();
    } catch (error) {
      App.error(error);
      list.innerHTML = '<div class="empty">Impossible de charger les événements. Réessayez plus tard ou contactez l’équipe.</div>';
      count.textContent = "";
    }
  };
})();
