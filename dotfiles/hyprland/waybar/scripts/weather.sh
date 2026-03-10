#!/bin/bash
# ── Waybar Weather Script ──
# Queries wttr.in for current conditions.
# Returns JSON: {"text": "22°C", "tooltip": "Partly cloudy, ..."}
#
# Edit LOCATION below or leave empty for IP-based geolocation.

LOCATION=""  # e.g. "Berlin" or "New+York" or leave empty

# Map wttr.in weather codes to Nerd Font icons
get_icon() {
    case "$1" in
        "113") echo "☀️" ;;       # Clear/Sunny
        "116") echo "⛅" ;;       # Partly cloudy
        "119"|"122") echo "☁️" ;; # Cloudy / Overcast
        "143"|"248"|"260") echo "🌫️" ;; # Fog
        "176"|"263"|"266"|"293"|"296"|"353") echo "🌦️" ;; # Light rain
        "299"|"302"|"305"|"308"|"356"|"359") echo "🌧️" ;; # Heavy rain
        "179"|"182"|"185"|"281"|"284"|"311"|"314"|"317") echo "🌨️" ;; # Sleet
        "200"|"386"|"389"|"392"|"395") echo "⛈️" ;; # Thunder
        "227"|"230"|"320"|"323"|"326"|"329"|"332"|"335"|"338"|"350"|"368"|"371"|"374"|"377") echo "❄️" ;; # Snow
        *) echo "🌡️" ;;
    esac
}

# Fetch weather data
WEATHER_DATA=$(curl -sf "https://wttr.in/${LOCATION}?format=j1" 2>/dev/null)

if [ -z "$WEATHER_DATA" ]; then
    echo '{"text": "N/A", "tooltip": "Weather unavailable"}'
    exit 0
fi

# Parse JSON with jq
TEMP=$(echo "$WEATHER_DATA" | jq -r '.current_condition[0].temp_C')
FEELS=$(echo "$WEATHER_DATA" | jq -r '.current_condition[0].FeelsLikeC')
HUMIDITY=$(echo "$WEATHER_DATA" | jq -r '.current_condition[0].humidity')
DESC=$(echo "$WEATHER_DATA" | jq -r '.current_condition[0].weatherDesc[0].value')
CODE=$(echo "$WEATHER_DATA" | jq -r '.current_condition[0].weatherCode')
WIND=$(echo "$WEATHER_DATA" | jq -r '.current_condition[0].windspeedKmph')

ICON=$(get_icon "$CODE")

TEXT="${TEMP}°C"
TOOLTIP="${ICON} ${DESC}\nFeels like: ${FEELS}°C\nHumidity: ${HUMIDITY}%\nWind: ${WIND} km/h"

echo "{\"text\": \"${ICON} ${TEXT}\", \"tooltip\": \"${TOOLTIP}\"}"
