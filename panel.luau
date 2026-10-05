--!nonstrict
-- Proton VPN Control Panel for Noctalia Shell
-- Provides full GUI-less control: Kill Switch, NetShield, Port Forwarding,
-- Split Tunneling, Countries on the fly, and live throughput.

local STATE_KEY = "protonvpn.status"
local COMMAND_KEY = "protonvpn.cmd"

local snapshot = noctalia.state.get(STATE_KEY) or {
  connected = false,
  connecting = false,
  busy = false,
  server = "",
  country = "",
  city = "",
  ip = "",
  protocol = "WireGuard",
  device = "proton0",
  signedIn = false,
  account = { username = "", plan = "" },
  config = { killSwitch = "off", netshield = "off", portForwarding = "off" },
  forwardedPort = nil,
  traffic = { rxRate = 0, txRate = 0, sessionRx = 0, sessionTx = 0, uptimeSec = 0 },
  splitTunneling = { available = false, enabled = false, apps = {}, candidates = {} },
  countries = {},
  cities = {},
  citiesFor = "",
  citiesLoading = false,
  servers = {},
  serversFor = "",
  serversForCity = "",
  serversLoading = false,
  stats = { countries = 0, cities = 0, servers = 0 },
  statusText = "Disconnected",
}

local activeTab = "connections" -- "connections" | "protection" | "account"
local filterText = ""
local selectedCountryCode = ""
local selectedCountryName = ""
local selectedCity = ""
local selectedAppToAdd = ""
local signinUserDraft = ""

local render

local function formatSpeed(bps)
  local v = tonumber(bps) or 0
  if v < 1024 then
    return string.format("%d B/s", v)
  elseif v < 1024 * 1024 then
    return string.format("%.1f KB/s", v / 1024)
  else
    return string.format("%.1f MB/s", v / (1024 * 1024))
  end
end

local function formatBytes(b)
  local v = tonumber(b) or 0
  if v < 1024 * 1024 then
    return string.format("%.1f KB", v / 1024)
  elseif v < 1024 * 1024 * 1024 then
    return string.format("%.1f MB", v / (1024 * 1024))
  else
    return string.format("%.2f GB", v / (1024 * 1024 * 1024))
  end
end

local function sendCmd(op, payload)
  local cmd = { op = op }
  if type(payload) == "table" then
    for k, v in pairs(payload) do
      cmd[k] = v
    end
  end
  noctalia.state.set(COMMAND_KEY, cmd)
end

-- ── Tab: Connections ──────────────────────────────────────────────────────
-- Hierarchy, all fetched live: countries → cities → servers. Nothing here is
-- hardcoded; every level comes from servers.py reading Proton's own cache.

local function openCountry(code, name)
  selectedCountryCode = code
  selectedCountryName = name
  selectedCity = ""
  filterText = ""
  sendCmd("get_cities", { country = code })
  render()
end

local function openCity(city)
  selectedCity = city
  filterText = ""
  sendCmd("get_servers", { country = selectedCountryCode, city = city })
  render()
end

local function backToCountries()
  selectedCountryCode = ""
  selectedCountryName = ""
  selectedCity = ""
  filterText = ""
  sendCmd("clear_selection")
  render()
end

local function backToCities()
  selectedCity = ""
  filterText = ""
  render()
end

local function joinTags(tags)
  if type(tags) ~= "table" or #tags == 0 then return "" end
  local parts = {}
  for _, t in ipairs(tags) do
    table.insert(parts, tostring(t))
  end
  return table.concat(parts, " · ")
end

local function renderConnectionsTab()
  local rows = {}

  -- Quick connect feature row
  table.insert(rows, ui.row({ gap = 6, align = "center" }, {
    ui.button({
      text = noctalia.tr("actions.fastest"),
      glyph = "bolt",
      variant = "outline",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        sendCmd("connect", { target = "fastest" })
      end,
    }),
    ui.button({
      text = "Random",
      glyph = "arrows-shuffle",
      variant = "outline",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        sendCmd("connect", { target = "random" })
      end,
    }),
    ui.button({
      text = "P2P",
      glyph = "download",
      variant = "outline",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        sendCmd("connect", { target = "p2p" })
      end,
    }),
    ui.button({
      text = "Tor",
      glyph = "eye-off",
      variant = "outline",
      controlSize = "sm",
      flexGrow = 1,
      onClick = function()
        sendCmd("connect", { target = "tor" })
      end,
    }),
  }))

  -- Live totals line (auto-fetched via servers.py --stats)
  local st = snapshot.stats or {}
  if (tonumber(st.servers) or 0) > 0 then
    table.insert(rows, ui.label({
      text = `{st.countries or 0} countries  ·  {st.cities or 0} cities  ·  {st.servers or 0} servers — live`,
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  local inCountry = selectedCountryCode ~= ""
  local inCity = inCountry and selectedCity ~= ""
  local query = noctalia.string.trim(filterText):lower()

  -- Search filter input (key per level so the field resets on drill-down)
  local searchKey = "search-countries"
  local searchPlaceholder = "Search country (e.g. US, Germany)..."
  if inCity then
    searchKey = `search-servers-{selectedCountryCode}-{selectedCity}`
    searchPlaceholder = `Search server in {selectedCity}...`
  elseif inCountry then
    searchKey = `search-cities-{selectedCountryCode}`
    searchPlaceholder = `Search city in {selectedCountryName}...`
  end
  table.insert(rows, ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = searchKey,
      value = filterText,
      placeholder = searchPlaceholder,
      flexGrow = 1,
      controlSize = "sm",
      onChange = "onSearchChange",
    }),
    ui.button({
      glyph = "x",
      variant = "ghost",
      controlSize = "sm",
      visible = filterText ~= "",
      onClick = function()
        filterText = ""
        render()
      end,
    }),
  }))

  -- ── Level 3: servers in a city ──────────────────────────────────────────
  if inCity then
    table.insert(rows, ui.row({ gap = 6, align = "center" }, {
      ui.button({
        glyph = "arrow-left",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          backToCities()
        end,
      }),
      ui.label({
        text = `{selectedCountryName}  ›  {selectedCity}`,
        fontSize = 13,
        fontWeight = "bold",
        flexGrow = 1,
      }),
    }))

    if snapshot.serversLoading or snapshot.serversFor ~= selectedCountryCode or snapshot.serversForCity ~= selectedCity then
      table.insert(rows, ui.column({ align = "center", padding = 20, gap = 6 }, {
        ui.label({ text = `Loading servers in {selectedCity}...`, color = "on_surface_variant", fontSize = 12 }),
      }))
      return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, rows)
    end

    local serverList = {}
    if snapshot.serversFor == selectedCountryCode and snapshot.serversForCity == selectedCity then
      serverList = snapshot.servers or {}
    end
    local listItems = {}
    for _, s in ipairs(serverList) do
      local sname = tostring(s.name or "")
      if sname ~= "" then
      local match = (query == "") or sname:lower():find(query, 1, true)
      if match then
        local currentServer = tostring(snapshot.server or ""):upper()
        local isCurrent = snapshot.connected and (currentServer == sname:upper())
        local load = tonumber(s.load) or 50
        local tierLabel = (tonumber(s.tier) == 0) and "Free" or "Plus"
        local tags = joinTags(s.tags)
        local sub = `{load}% load  ·  {tierLabel}`
        if tags ~= "" then sub = `{sub}  ·  {tags}` end
        local rowCode = sname
        table.insert(listItems, ui.row({
          key = `server-{rowCode}`,
          align = "center",
          paddingV = 6,
          paddingH = 8,
          radius = 8,
          fill = isCurrent and "primary/0.15" or "surface_variant/0.3",
        }, {
          ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({
              text = sname,
              fontSize = 13,
              fontWeight = isCurrent and "bold" or "normal",
              color = isCurrent and "primary" or "on_surface",
            }),
            ui.label({ text = sub, fontSize = 11, color = "on_surface_variant" }),
          }),
          ui.button({
            text = isCurrent and noctalia.tr("status.connected") or noctalia.tr("actions.connect"),
            variant = isCurrent and "primary" or "outline",
            glyph = isCurrent and "check" or "player-play",
            controlSize = "sm",
            enabled = not isCurrent and not snapshot.busy,
            onClick = function()
              sendCmd("connect", { target = rowCode, kind = "server" })
            end,
          }),
        }))
      end
      end
    end

    if #listItems == 0 then
      table.insert(rows, ui.column({ align = "center", padding = 20, gap = 6 }, {
        ui.glyph({ name = "search", size = 28, color = "on_surface_variant" }),
        ui.label({ text = "No matching servers found", color = "on_surface_variant", fontSize = 12 }),
      }))
    else
      table.insert(rows, ui.scroll({
        key = `servers-scroll-{selectedCountryCode}-{selectedCity}`,
        flexGrow = 1,
        gap = 6,
        align = "stretch",
      }, listItems))
    end
    return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, rows)
  end

  -- ── Level 2: cities in a country ────────────────────────────────────────
  if inCountry then
    table.insert(rows, ui.row({ gap = 6, align = "center" }, {
      ui.button({
        glyph = "arrow-left",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          backToCountries()
        end,
      }),
      ui.label({
        text = selectedCountryName ~= "" and selectedCountryName or selectedCountryCode,
        fontSize = 13,
        fontWeight = "bold",
        flexGrow = 1,
      }),
    }))

    if snapshot.citiesLoading or snapshot.citiesFor ~= selectedCountryCode then
      table.insert(rows, ui.column({ align = "center", padding = 20, gap = 6 }, {
        ui.label({ text = `Loading cities in {selectedCountryName}...`, color = "on_surface_variant", fontSize = 12 }),
      }))
      return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, rows)
    end

    local cityList = {}
    if snapshot.citiesFor == selectedCountryCode then
      cityList = snapshot.cities or {}
    end
    local listItems = {}
    for _, c in ipairs(cityList) do
      local city = tostring(c.city or "")
      if city ~= "" then
      local best = tostring(c.name or "")
      local match = (query == "") or city:lower():find(query, 1, true) or best:lower():find(query, 1, true)
      if match then
        local currentCity = tostring(snapshot.city or ""):lower()
        local isCurrentCity = snapshot.connected and (currentCity == city:lower())
        local load = tonumber(c.load) or 50
        local tags = joinTags(c.tags)
        local sub = `Fastest: {best}  ·  {load}%`
        if tags ~= "" then sub = `{sub}  ·  {tags}` end
        sub = `{sub}  ·  {c.count or 0} servers`
        local rowCity = city
        table.insert(listItems, ui.row({
          key = `city-{selectedCountryCode}-{rowCity}`,
          align = "center",
          paddingV = 6,
          paddingH = 8,
          radius = 8,
          fill = isCurrentCity and "primary/0.15" or "surface_variant/0.3",
        }, {
          ui.column({ flexGrow = 1, gap = 2 }, {
            ui.label({
              text = rowCity,
              fontSize = 13,
              fontWeight = isCurrentCity and "bold" or "normal",
              color = isCurrentCity and "primary" or "on_surface",
            }),
            ui.label({ text = sub, fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
          }),
          ui.button({
            text = noctalia.tr("actions.connect"),
            variant = "outline",
            glyph = "player-play",
            controlSize = "sm",
            enabled = not snapshot.busy,
            onClick = function()
              sendCmd("connect", { target = rowCity, kind = "city" })
            end,
          }),
          ui.button({
            glyph = "chevron-right",
            variant = "ghost",
            controlSize = "sm",
            onClick = function()
              openCity(rowCity)
            end,
          }),
        }))
      end
      end
    end

    if #listItems == 0 then
      table.insert(rows, ui.column({ align = "center", padding = 20, gap = 6 }, {
        ui.glyph({ name = "search", size = 28, color = "on_surface_variant" }),
        ui.label({ text = "No matching cities found", color = "on_surface_variant", fontSize = 12 }),
      }))
    else
      table.insert(rows, ui.scroll({
        key = `cities-scroll-{selectedCountryCode}`,
        flexGrow = 1,
        gap = 6,
        align = "stretch",
      }, listItems))
    end
    return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, rows)
  end

  -- ── Level 1: all countries ──────────────────────────────────────────────
  local countryList = snapshot.countries or {}
  if #countryList == 0 then
    table.insert(rows, ui.column({ align = "center", padding = 20, gap = 8 }, {
      ui.glyph({ name = "world", size = 28, color = "on_surface_variant" }),
      ui.label({ text = "Fetching live server list...", color = "on_surface_variant", fontSize = 12 }),
      ui.button({
        text = "Retry",
        glyph = "refresh",
        variant = "outline",
        controlSize = "sm",
        onClick = function()
          sendCmd("refresh")
        end,
      }),
    }))
    return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, rows)
  end

  local listItems = {}
  for _, c in ipairs(countryList) do
    local code = tostring(c.code or "")
    local name = tostring(c.name or code)
    if code ~= "" then
    local match = (query == "") or name:lower():find(query, 1, true) or code:lower():find(query, 1, true)

    if match then
      local upperCountry = tostring(snapshot.country or ""):upper()
      local isCurrentCountry = snapshot.connected and (upperCountry == code:upper() or upperCountry == name:upper())
      local rowCode = code
      local rowName = name

      table.insert(listItems, ui.row({
        key = `country-{rowCode}`,
        align = "center",
        paddingV = 6,
        paddingH = 8,
        radius = 8,
        fill = isCurrentCountry and "primary/0.15" or "surface_variant/0.3",
      }, {
        ui.row({
          width = 34,
          height = 24,
          radius = 4,
          fill = isCurrentCountry and "primary" or "surface_variant",
          align = "center",
          justify = "center",
        }, {
          ui.label({
            text = rowCode,
            fontSize = 11,
            fontWeight = "bold",
            color = isCurrentCountry and "on_primary" or "on_surface_variant",
          }),
        }),
        ui.column({ flexGrow = 1, gap = 2 }, {
          ui.label({
            text = rowName,
            fontSize = 13,
            fontWeight = isCurrentCountry and "bold" or "normal",
            color = isCurrentCountry and "primary" or "on_surface",
          }),
          ui.label({
            text = `{c.count or 0} servers  ·  {c.cities or 0} cities  ·  {c.load or 50}% load`,
            fontSize = 11,
            color = "on_surface_variant",
          }),
        }),
        ui.button({
          text = isCurrentCountry and noctalia.tr("status.connected") or noctalia.tr("actions.connect"),
          variant = isCurrentCountry and "primary" or "outline",
          glyph = isCurrentCountry and "check" or "player-play",
          controlSize = "sm",
          enabled = not isCurrentCountry and not snapshot.busy,
          onClick = function()
            sendCmd("connect", { target = rowCode, kind = "country" })
          end,
        }),
        ui.button({
          glyph = "chevron-right",
          variant = "ghost",
          controlSize = "sm",
          onClick = function()
            openCountry(rowCode, rowName)
          end,
        }),
      }))
    end
    end
  end

  if #listItems == 0 then
    table.insert(rows, ui.column({ align = "center", padding = 20, gap = 6 }, {
      ui.glyph({ name = "search", size = 28, color = "on_surface_variant" }),
      ui.label({ text = "No matching countries found", color = "on_surface_variant", fontSize = 12 }),
    }))
  else
    table.insert(rows, ui.scroll({
      key = "countries-scroll",
      flexGrow = 1,
      gap = 6,
      align = "stretch",
    }, listItems))
  end

  return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, rows)
end

-- ── Tab: Protection ───────────────────────────────────────────────────────

local function renderProtectionTab()
  local rows = {}

  -- 1. Kill Switch
  local ksOn = (snapshot.config.killSwitch == "standard")
  table.insert(rows, ui.column({
    padding = 10,
    radius = 10,
    fill = "surface_variant/0.45",
    gap = 6,
    align = "stretch",
  }, {
    ui.row({ align = "center" }, {
      ui.glyph({ name = "shield-lock", size = 18, color = ksOn and "primary" or "on_surface_variant" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("protection.killswitch"), fontWeight = "bold", fontSize = 13 }),
        ui.label({ text = noctalia.tr("protection.killswitch_desc"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.toggle({
        checked = ksOn,
        enabled = not snapshot.busy,
        onChange = function(checked)
          local val = (checked == "true" or checked == true) and "standard" or "off"
          sendCmd("set_killswitch", { value = val })
        end,
      }),
    }),
  }))

  -- 2. NetShield Ad/Malware Blocker
  local nsVal = snapshot.config.netshield or "off"
  table.insert(rows, ui.column({
    padding = 10,
    radius = 10,
    fill = "surface_variant/0.45",
    gap = 8,
    align = "stretch",
  }, {
    ui.row({ align = "center" }, {
      ui.glyph({ name = "shield-check", size = 18, color = (nsVal ~= "off") and "primary" or "on_surface_variant" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("protection.netshield"), fontWeight = "bold", fontSize = 13 }),
        ui.label({ text = noctalia.tr("protection.netshield_desc"), fontSize = 11, color = "on_surface_variant" }),
      }),
    }),
    ui.row({ gap = 6, align = "center" }, {
      ui.button({
        text = noctalia.tr("protection.netshield_off"),
        variant = (nsVal == "off") and "primary" or "outline",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          sendCmd("set_netshield", { value = "off" })
        end,
      }),
      ui.button({
        text = noctalia.tr("protection.netshield_malware"),
        variant = (nsVal == "malware-only") and "primary" or "outline",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          sendCmd("set_netshield", { value = "malware-only" })
        end,
      }),
      ui.button({
        text = noctalia.tr("protection.netshield_all"),
        variant = (nsVal == "malware-ads-trackers") and "primary" or "outline",
        controlSize = "sm",
        flexGrow = 1,
        onClick = function()
          sendCmd("set_netshield", { value = "malware-ads-trackers" })
        end,
      }),
    }),
  }))

  -- 3. Port Forwarding
  local pfOn = (snapshot.config.portForwarding == "on")
  local portChildren = {
    ui.row({ align = "center" }, {
      ui.glyph({ name = "network", size = 18, color = pfOn and "primary" or "on_surface_variant" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("protection.port_forwarding"), fontWeight = "bold", fontSize = 13 }),
        ui.label({ text = noctalia.tr("protection.port_forwarding_desc"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.toggle({
        checked = pfOn,
        enabled = not snapshot.busy,
        onChange = function(checked)
          local val = (checked == "true" or checked == true) and "on" or "off"
          sendCmd("set_port_forwarding", { value = val })
        end,
      }),
    }),
  }

  if pfOn and snapshot.forwardedPort then
    table.insert(portChildren, ui.row({
      gap = 8,
      align = "center",
      padding = 8,
      radius = 6,
      fill = "primary/0.15",
    }, {
      ui.label({
        text = `Forwarded Inbound Port: {snapshot.forwardedPort}`,
        fontWeight = "bold",
        color = "primary",
        fontSize = 12,
        flexGrow = 1,
      }),
      ui.button({
        text = noctalia.tr("actions.copy_port"),
        glyph = "copy",
        variant = "outline",
        controlSize = "xs",
        onClick = function()
          noctalia.copyToClipboard(tostring(snapshot.forwardedPort), "text/plain")
          noctalia.notify(noctalia.tr("title"), `Port {snapshot.forwardedPort} copied to clipboard`)
        end,
      }),
    }))
  end

  table.insert(rows, ui.column({
    padding = 10,
    radius = 10,
    fill = "surface_variant/0.45",
    gap = 6,
    align = "stretch",
  }, portChildren))

  -- 4. Split Tunneling
  local stAvailable = (snapshot.splitTunneling and snapshot.splitTunneling.available == true)
  local stOn = (snapshot.splitTunneling and snapshot.splitTunneling.enabled == true)
  local splitChildren = {
    ui.row({ align = "center" }, {
      ui.glyph({ name = "route", size = 18, color = stOn and "primary" or "on_surface_variant" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({ text = noctalia.tr("protection.split_tunneling"), fontWeight = "bold", fontSize = 13 }),
        ui.label({ text = noctalia.tr("protection.split_tunneling_desc"), fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.toggle({
        checked = stOn,
        enabled = stAvailable and (not ksOn),
        onChange = function()
          sendCmd("toggle_split")
        end,
      }),
    }),
  }

  if ksOn then
    table.insert(splitChildren, ui.label({
      text = noctalia.tr("protection.split_tunneling_warning"),
      fontSize = 11,
      color = "on_surface_variant",
    }))
  end

  if not stAvailable then
    table.insert(splitChildren, ui.label({
      text = "Connect once with Proton VPN to initialize configuration.",
      fontSize = 11,
      color = "on_surface_variant",
    }))
  elseif stOn then
    local appRows = {}
    local apps = snapshot.splitTunneling.apps or {}
    for _, path in ipairs(apps) do
      local appName = path:match("([^/]+)$") or path
      table.insert(appRows, ui.row({
        key = `split-{path}`,
        align = "center",
        paddingV = 4,
        paddingH = 6,
        radius = 6,
        fill = "surface_variant/0.3",
      }, {
        ui.glyph({ name = "app-window", size = 14, color = "on_surface_variant" }),
        ui.label({ text = appName, fontSize = 12, flexGrow = 1, maxLines = 1 }),
        ui.button({
          glyph = "trash",
          variant = "ghost",
          controlSize = "xs",
          onClick = function()
            sendCmd("remove_split_app", { path = path })
          end,
        }),
      }))
    end

    if #appRows > 0 then
      table.insert(splitChildren, ui.column({ gap = 4, align = "stretch" }, appRows))
    else
      table.insert(splitChildren, ui.label({
        text = "No apps excluded yet.",
        fontSize = 11,
        color = "on_surface_variant",
      }))
    end

    -- Add app candidates row
    local candidates = snapshot.splitTunneling.candidates or {}
    if #candidates > 0 then
      local candidateNames = {}
      for idx, c in ipairs(candidates) do
        if idx <= 30 then
          table.insert(candidateNames, c.label or c.value)
        end
      end

      table.insert(splitChildren, ui.row({ gap = 6, align = "center" }, {
        ui.select({
          key = "split-app-select",
          options = candidateNames,
          placeholder = "Select app to exclude...",
          flexGrow = 1,
          controlSize = "sm",
          onChange = function(val)
            local idx = tonumber(val)
            if idx and candidates[idx + 1] then
              selectedAppToAdd = candidates[idx + 1].value
            end
          end,
        }),
        ui.button({
          text = "Add",
          glyph = "plus",
          variant = "outline",
          controlSize = "sm",
          enabled = selectedAppToAdd ~= "",
          onClick = function()
            if selectedAppToAdd ~= "" then
              sendCmd("add_split_app", { path = selectedAppToAdd })
              selectedAppToAdd = ""
            end
          end,
        }),
      }))
    end
  end

  table.insert(rows, ui.column({
    padding = 10,
    radius = 10,
    fill = "surface_variant/0.45",
    gap = 6,
    align = "stretch",
  }, splitChildren))

  return ui.scroll({
    key = "protection-scroll",
    flexGrow = 1,
    gap = 10,
    align = "stretch",
  }, rows)
end

-- ── Tab: Account ──────────────────────────────────────────────────────────

local function renderAccountTab()
  local rows = {}

  local signedIn = (snapshot.signedIn == true)
  local username = snapshot.account and snapshot.account.username or ""
  local plan = snapshot.account and snapshot.account.plan or ""

  table.insert(rows, ui.column({
    padding = 12,
    radius = 10,
    fill = "surface_variant/0.45",
    gap = 8,
    align = "stretch",
  }, {
    ui.row({ align = "center", gap = 10 }, {
      ui.glyph({ name = signedIn and "user-check" or "user-x", size = 28, color = signedIn and "primary" or "error" }),
      ui.column({ flexGrow = 1, gap = 2 }, {
        ui.label({
          text = signedIn and (username ~= "" and username or "Proton User") or noctalia.tr("account.not_signed_in"),
          fontWeight = "bold",
          fontSize = 15,
        }),
        ui.label({
          text = signedIn and (plan ~= "" and `{noctalia.tr("account.plan")}: {plan}` or "Account active") or noctalia.tr("account.signin_hint"),
          fontSize = 12,
          color = "on_surface_variant",
        }),
      }),
    }),
  }))

  if not signedIn then
    table.insert(rows, ui.column({ gap = 10, padding = 12, align = "stretch", radius = 10, fill = "surface_variant/0.35" }, {
      ui.label({
        text = "Enter your Proton username or email below to sign in:",
        fontSize = 12,
        fontWeight = "bold",
        color = "on_surface",
      }),
      ui.input({
        key = "signin-username-input",
        value = signinUserDraft,
        placeholder = "Proton username or email (e.g. user@proton.me)...",
        controlSize = "sm",
        onChange = function(v)
          signinUserDraft = tostring(v or "")
        end,
      }),
      ui.button({
        text = noctalia.tr("actions.signin"),
        glyph = "login",
        variant = "primary",
        onClick = function()
          sendCmd("signin", { username = signinUserDraft })
        end,
      }),
      ui.label({
        text = "A secure terminal will prompt for your Proton password & 2FA.",
        fontSize = 11,
        color = "on_surface_variant",
      }),
    }))
  else
    table.insert(rows, ui.row({ gap = 8, align = "center" }, {
      ui.button({
        text = noctalia.tr("actions.signout"),
        glyph = "logout",
        variant = "outline",
        flexGrow = 1,
        onClick = function()
          sendCmd("signout")
        end,
      }),
      ui.button({
        text = "Refresh Status",
        glyph = "refresh",
        variant = "ghost",
        onClick = function()
          sendCmd("refresh")
        end,
      }),
    }))
  end

  -- Settings & Documentation Links
  table.insert(rows, ui.column({ gap = 6, padding = 10, align = "stretch" }, {
    ui.label({ text = "Information", fontWeight = "bold", fontSize = 12 }),
    ui.row({ gap = 6 }, {
      ui.label({ text = "CLI Version:", fontSize = 11, color = "on_surface_variant", width = 100 }),
      ui.label({ text = "Proton VPN CLI v1.0.3", fontSize = 11, flexGrow = 1 }),
    }),
    ui.row({ gap = 6 }, {
      ui.label({ text = "Protocol:", fontSize = 11, color = "on_surface_variant", width = 100 }),
      ui.label({ text = snapshot.protocol or "WireGuard", fontSize = 11, flexGrow = 1 }),
    }),
    ui.row({ gap = 6 }, {
      ui.label({ text = "Tunnel Interface:", fontSize = 11, color = "on_surface_variant", width = 100 }),
      ui.label({ text = snapshot.device ~= "" and snapshot.device or "proton0", fontSize = 11, flexGrow = 1 }),
    }),
  }))

  return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, rows)
end

-- ── Main Render ───────────────────────────────────────────────────────────

render = function()
  local connected = (snapshot.connected == true)
  local connecting = (snapshot.connecting == true)

  -- Top Connection Card
  local connCardChildren = {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({
        name = connected and "shield-check" or "shield-lock",
        size = 22,
        color = connected and "primary" or "on_surface_variant",
      }),
      ui.column({ flexGrow = 1, gap = 1 }, {
        ui.label({
          text = connected and (snapshot.server ~= "" and snapshot.server or noctalia.tr("status.connected")) or (connecting and noctalia.tr("status.connecting") or (snapshot.signedIn and noctalia.tr("status.disconnected") or noctalia.tr("account.not_signed_in"))),
          fontWeight = "bold",
          fontSize = 15,
        }),
        ui.label({
          text = connected and (`{snapshot.city ~= "" and (snapshot.city .. ", ") or ""}{snapshot.country}  ·  {snapshot.ip}`) or (snapshot.signedIn and "No active tunnel" or noctalia.tr("account.signin_hint")),
          fontSize = 11,
          color = "on_surface_variant",
          maxLines = 1,
        }),
      }),
      ui.button({
        text = connected and noctalia.tr("actions.disconnect") or (snapshot.signedIn and noctalia.tr("actions.quick_connect") or noctalia.tr("actions.signin")),
        variant = connected and "outline" or "primary",
        glyph = connected and "player-stop" or (snapshot.signedIn and "player-play" or "login"),
        controlSize = "sm",
        enabled = not snapshot.busy,
        onClick = function()
          if connected then
            sendCmd("disconnect")
          elseif snapshot.signedIn then
            sendCmd("connect", { target = "fastest" })
          else
            activeTab = "account"
            render()
          end
        end,
      }),
    }),
  }

  -- If connected: live bandwidth stats
  if connected and snapshot.traffic then
    local rx = formatSpeed(snapshot.traffic.rxRate or 0)
    local tx = formatSpeed(snapshot.traffic.txRate or 0)
    local totRx = formatBytes(snapshot.traffic.sessionRx or 0)
    local totTx = formatBytes(snapshot.traffic.sessionTx or 0)

    table.insert(connCardChildren, ui.row({
      gap = 12,
      align = "center",
      paddingT = 4,
    }, {
      ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = "arrow-down", size = 13, color = "primary" }),
        ui.label({ text = rx, fontSize = 11, fontWeight = "bold" }),
        ui.label({ text = `({totRx})`, fontSize = 10, color = "on_surface_variant" }),
      }),
      ui.row({ gap = 4, align = "center" }, {
        ui.glyph({ name = "arrow-up", size = 13, color = "secondary" }),
        ui.label({ text = tx, fontSize = 11, fontWeight = "bold" }),
        ui.label({ text = `({totTx})`, fontSize = 10, color = "on_surface_variant" }),
      }),
    }))
  end

  local topCard = ui.column({
    padding = 12,
    radius = 12,
    fill = connected and "primary/0.12" or "surface_variant/0.4",
    gap = 4,
    align = "stretch",
  }, connCardChildren)

  -- Tab Navigation
  local tabNav = ui.row({ gap = 4, align = "center" }, {
    ui.button({
      text = noctalia.tr("tabs.connections"),
      glyph = "world",
      variant = (activeTab == "connections") and "primary" or "ghost",
      flexGrow = 1,
      onClick = function()
        activeTab = "connections"
        render()
      end,
    }),
    ui.button({
      text = noctalia.tr("tabs.protection"),
      glyph = "shield",
      variant = (activeTab == "protection") and "primary" or "ghost",
      flexGrow = 1,
      onClick = function()
        activeTab = "protection"
        render()
      end,
    }),
    ui.button({
      text = noctalia.tr("tabs.account"),
      glyph = "user",
      variant = (activeTab == "account") and "primary" or "ghost",
      flexGrow = 1,
      onClick = function()
        activeTab = "account"
        render()
      end,
    }),
  })

  -- Tab Content
  local content
  if activeTab == "connections" then
    content = renderConnectionsTab()
  elseif activeTab == "protection" then
    content = renderProtectionTab()
  else
    content = renderAccountTab()
  end

  -- Main Panel Layout
  panel.render(ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, {
    -- Header
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "shield-lock-filled", size = 20, color = "primary" }),
      ui.label({ text = noctalia.tr("title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
      ui.button({
        glyph = "refresh",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          sendCmd("refresh")
        end,
      }),
      ui.button({
        glyph = "x",
        variant = "ghost",
        controlSize = "sm",
        onClick = function()
          noctalia.togglePanel("riversyx/noctaproton-vpn:panel")
        end,
      }),
    }),
    topCard,
    tabNav,
    content,
  }))
end

noctalia.state.watch(STATE_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

function onSearchChange(val)
  filterText = if type(val) == "string" then val else ""
  render()
end

render()
