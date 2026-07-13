import Foundation
import AitvarasCore

/// Built-in homelab connectors (D10) expressed as manifests on the
/// GenericHTTPConnector engine (D17). Read-only by design: API tokens are
/// scoped read-only server-side (auditor role, non-admin HA user), and
/// every tool here is `risk: .read` — no shell, no writes.
///
/// Base URLs are runtime configuration (kv store, e.g. "hypervisor.baseURL"),
/// so these are functions, not constants. Secrets live in the Keychain
/// under the `keychainKey` each manifest names.
public enum BundledManifests {

    /// Keychain keys the settings UI should populate.
    public static let hypervisorTokenKey = "hypervisor.apiToken"
    public static let nasTokenKey = "nas.apiKey"
    public static let homeAssistantTokenKey = "homeassistant.token"

    /// Hypervisor. Token format is "user@realm!tokenname=uuid"; the API
    /// wants it raw after a literal "APIToken=" prefix — hence auth type
    /// `header` with `valuePrefix` instead of bearer.
    public static func hypervisor(baseURL: String) -> ConnectorManifest {
        ConnectorManifest(
            id: "hypervisor",
            displayName: "Hypervisor",
            baseURL: baseURL,
            auth: .init(type: .header, keychainKey: hypervisorTokenKey,
                        headerName: "Authorization", valuePrefix: "APIToken="),
            tools: [
                .init(
                    name: "cluster_status",
                    description: "All Hypervisor cluster resources (VMs, containers, storage, nodes) with status, CPU and memory usage.",
                    method: "GET",
                    path: "/api/v1/cluster/resources",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read),
                .init(
                    name: "nodes",
                    description: "Hypervisor nodes with uptime, load and status.",
                    method: "GET",
                    path: "/api/v1/nodes",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read)
            ])
    }

    /// NAS REST API v2.0, bearer token auth.
    public static func nas(baseURL: String) -> ConnectorManifest {
        ConnectorManifest(
            id: "nas",
            displayName: "NAS",
            baseURL: baseURL,
            auth: .init(type: .bearer, keychainKey: nasTokenKey),
            tools: [
                .init(
                    name: "system_info",
                    description: "NAS system information: version, uptime, hardware, memory.",
                    method: "GET",
                    path: "/api/v2.0/system/info",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read),
                .init(
                    name: "pools",
                    description: "NAS storage pools with health status, capacity and usage.",
                    method: "GET",
                    path: "/api/v2.0/pool",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read)
            ])
    }

    /// Home Assistant REST API, long-lived access token (non-admin user).
    /// `/api/states` can be enormous — the engine truncates every response
    /// to its 6000-char limit; prefer ha_entity for specific devices.
    public static func homeAssistant(baseURL: String) -> ConnectorManifest {
        ConnectorManifest(
            id: "homeassistant",
            displayName: "Home Assistant",
            baseURL: baseURL,
            auth: .init(type: .bearer, keychainKey: homeAssistantTokenKey),
            tools: [
                .init(
                    name: "ha_states",
                    description: "All Home Assistant entity states. Output is truncated — when you know the entity, use ha_entity instead.",
                    method: "GET",
                    path: "/api/states",
                    parametersJSON: #"{"type":"object","properties":{},"required":[]}"#,
                    risk: .read),
                .init(
                    name: "ha_entity",
                    description: "State and attributes of one Home Assistant entity, e.g. 'sensor.living_room_temperature'.",
                    method: "GET",
                    path: "/api/states/{entity_id}",
                    parametersJSON: #"{"type":"object","properties":{"entity_id":{"type":"string","description":"Entity id like 'light.desk' or 'sensor.cpu_temp'"}},"required":["entity_id"]}"#,
                    risk: .read)
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
                    description: "Latitude/longitude and country for a city name (e.g. 'Berlin'). Use before weather.forecast.",
                    method: "GET",
                    path: "/v1/search?count=3&language=de&format=json",
                    parametersJSON: #"{"type":"object","properties":{"name":{"type":"string","description":"City name"}},"required":["name"]}"#,
                    risk: .read)
            ])
    }
}
