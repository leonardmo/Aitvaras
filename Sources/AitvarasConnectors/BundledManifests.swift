import Foundation
import AitvarasCore

/// Built-in homelab connector capabilities (D10). Proxmox and TrueNAS run
/// directly through GenericHTTPConnector. Home Assistant reuses its manifest
/// metadata but has a constrained adapter for searchable state summaries and
/// idempotent light writes. No connector exposes shell access.
///
/// Base URLs are runtime configuration (kv store, e.g. "proxmox.baseURL"),
/// so these are functions, not constants. Secrets live in the Keychain
/// under the `keychainKey` each manifest names.
public enum BundledManifests {

    /// Keychain keys the settings UI should populate.
    public static let proxmoxTokenKey = "proxmox.apiToken"
    public static let trueNASTokenKey = "truenas.apiKey"
    public static let homeAssistantTokenKey = "homeassistant.token"

    /// Proxmox VE. Token format is "user@realm!tokenname=uuid"; the API
    /// wants it raw after a literal "PVEAPIToken=" prefix — hence auth type
    /// `header` with `valuePrefix` instead of bearer.
    public static func proxmox(baseURL: String) -> ConnectorManifest {
        ConnectorManifest(
            id: "proxmox",
            displayName: "Proxmox",
            baseURL: baseURL,
            auth: .init(type: .header, keychainKey: proxmoxTokenKey,
                        headerName: "Authorization", valuePrefix: "PVEAPIToken="),
            tools: [
                .init(
                    name: "cluster_status",
                    description: "All Proxmox cluster resources (VMs, containers, storage, nodes) with status, CPU and memory usage.",
                    method: "GET",
                    path: "/api2/json/cluster/resources",
                    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
                    risk: .read),
                .init(
                    name: "nodes",
                    description: "Proxmox nodes with uptime, load and status.",
                    method: "GET",
                    path: "/api2/json/nodes",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read)
            ])
    }

    /// TrueNAS SCALE REST API v2.0, bearer token auth.
    public static func trueNAS(baseURL: String) -> ConnectorManifest {
        ConnectorManifest(
            id: "truenas",
            displayName: "TrueNAS",
            baseURL: baseURL,
            auth: .init(type: .bearer, keychainKey: trueNASTokenKey),
            tools: [
                .init(
                    name: "system_info",
                    description: "TrueNAS system information: version, uptime, hardware, memory.",
                    method: "GET",
                    path: "/api/v2.0/system/info",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read),
                .init(
                    name: "pools",
                    description: "TrueNAS storage pools with health status, capacity and usage.",
                    method: "GET",
                    path: "/api/v2.0/pool",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read)
            ])
    }

    /// Home Assistant REST API, long-lived access token (non-admin user).
    /// HomeAssistantConnector interprets these tools; it compacts the large
    /// state inventory and validates every exact entity id before a write.
    public static func homeAssistant(baseURL: String) -> ConnectorManifest {
        ConnectorManifest(
            id: "homeassistant",
            displayName: "Home Assistant",
            baseURL: baseURL,
            auth: .init(type: .bearer, keychainKey: homeAssistantTokenKey),
            tools: [
                .init(
                    name: "ha_states",
                    description: "Compact Home Assistant inventory with entity counts by domain. Use search_entities to find exact ids before reading or controlling one.",
                    method: "GET",
                    path: "/api/states",
                    parametersJSON: #"{"type":"object","properties":{},"required":[],"additionalProperties":false}"#,
                    risk: .read),
                .init(
                    name: "search_entities",
                    description: "Search Home Assistant entities by friendly name or exact-id text, optionally narrowed by domain or state. Use this before acting when the exact entity id is unknown.",
                    method: "GET",
                    path: "/api/states",
                    parametersJSON: #"{"type":"object","properties":{"query":{"type":"string","description":"Friendly-name or entity-id text, e.g. desk or living room"},"domain":{"type":"string","pattern":"^[a-z0-9_]+$","description":"Optional domain such as light, sensor or climate"},"state":{"type":"string","description":"Optional exact state such as on, off or unavailable"},"limit":{"type":"integer","minimum":1,"maximum":50,"default":20}},"required":[],"additionalProperties":false}"#,
                    risk: .read),
                .init(
                    name: "ha_entity",
                    description: "Compact state and safe operational attributes of one exact Home Assistant entity.",
                    method: "GET",
                    path: "/api/states/{entity_id}",
                    parametersJSON: #"{"type":"object","properties":{"entity_id":{"type":"string","pattern":"^[a-z0-9_]+\\.[a-z0-9_]+$","description":"Exact entity id such as light.desk or sensor.cpu_temp"}},"required":["entity_id"],"additionalProperties":false}"#,
                    risk: .read),
                .init(
                    name: "light_off",
                    description: "Idempotently turn off one exact Home Assistant light entity. Search first when its id is unknown.",
                    method: "POST",
                    path: "/api/services/light/turn_off",
                    parametersJSON: #"{"type":"object","properties":{"entity_id":{"type":"string","pattern":"^light\\.[a-z0-9_]+$","description":"Exact light entity id, e.g. light.desk"},"transition_seconds":{"type":"integer","minimum":0,"maximum":30}},"required":["entity_id"],"additionalProperties":false}"#,
                    risk: .reversibleWrite,
                    bodyTemplate: #"{"entity_id":"{entity_id}"}"#),
                .init(
                    name: "light_on",
                    description: "Idempotently turn on one exact Home Assistant light entity, optionally with brightness and a short transition. Search first when its id is unknown.",
                    method: "POST",
                    path: "/api/services/light/turn_on",
                    parametersJSON: #"{"type":"object","properties":{"entity_id":{"type":"string","pattern":"^light\\.[a-z0-9_]+$","description":"Exact light entity id, e.g. light.desk"},"brightness_pct":{"type":"integer","minimum":1,"maximum":100},"transition_seconds":{"type":"integer","minimum":0,"maximum":30}},"required":["entity_id"],"additionalProperties":false}"#,
                    risk: .reversibleWrite,
                    bodyTemplate: #"{"entity_id":"{entity_id}"}"#)
            ])
    }

    /// Open-Meteo weather (open-meteo.com): free, no key, no account —
    /// registered unconditionally. Two manifests because geocoding lives
    /// on its own host; the model chains geocode_city → forecast.
    public static func openMeteoWeather() -> ConnectorManifest {
        ConnectorManifest(
            id: "weather",
            displayName: "Weather (Open-Meteo)",
            baseURL: "https://api.open-meteo.com",
            auth: .init(type: .none),
            tools: [
                .init(
                    name: "forecast",
                    description: "Weather forecast (current conditions + 7 days daily min/max temperature °C, precipitation probability %, wind km/h, WMO weather code) for coordinates. Get coordinates for a city with geocode.geocode_city first.",
                    method: "GET",
                    path: "/v1/forecast?daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,weather_code,wind_speed_10m_max&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&timezone=auto&forecast_days=7",
                    parametersJSON: #"{"type":"object","properties":{"latitude":{"type":"number"},"longitude":{"type":"number"}},"required":["latitude","longitude"]}"#,
                    risk: .read)
            ])
    }

    public static func openMeteoGeocoding() -> ConnectorManifest {
        ConnectorManifest(
            id: "geocode",
            displayName: "Geocoding (Open-Meteo)",
            baseURL: "https://geocoding-api.open-meteo.com",
            auth: .init(type: .none),
            tools: [
                .init(
                    name: "geocode_city",
                    description: "Latitude/longitude and country for a city name (e.g. 'München'). Use before weather.forecast.",
                    method: "GET",
                    path: "/v1/search?count=3&language=de&format=json",
                    parametersJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"City name"}},"required":["name"]}"#,
                    risk: .read)
            ])
    }
}
