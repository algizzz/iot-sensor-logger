# IoT Sensor Logger

## Project Overview

This project provides a comprehensive, Docker-based stack for IoT sensor data collection, storage, visualization, and management. It's designed to be a robust and scalable solution for logging and monitoring sensor readings from multiple devices.

The stack is composed of several key services, each running in its own Docker container, ensuring modularity and ease of deployment.

## Architecture

The data flows through the system in a clear, unidirectional path:

**IoT Device -> Mosquitto (MQTT) -> Telegraf -> InfluxDB -> Grafana / API**

This architecture ensures that the system is easy to understand, debug, and scale.

![Architecture Diagram](https://raw.githubusercontent.com/algizzz/iot-sensor-logger/main/docs/architecture.png) 

*(Note: The diagram is a representation of the architecture and is not dynamically generated)*

### Core Components

*   **Mosquitto:** An open-source MQTT broker that acts as the central hub for incoming sensor data. IoT devices publish their readings to specific topics on this broker.
*   **Telegraf:** A plugin-driven server agent for collecting and reporting metrics. In this stack, it subscribes to the MQTT topics, parses the JSON-formatted sensor data, and writes it into the InfluxDB time-series database.
*   **InfluxDB:** A high-performance database specifically designed for handling time-series data. It efficiently stores sensor readings like temperature, humidity, and pressure for later querying and analysis.
*   **Grafana:** A leading open-source platform for data visualization, monitoring, and analysis. It connects to InfluxDB as a data source and provides a powerful and customizable interface for creating dashboards to visualize the sensor data in real-time.
*   **API (FastAPI):** A modern, fast (high-performance) web framework for building APIs with Python. This custom-built API provides secure, token-based RESTful endpoints to query sensor data from InfluxDB, allowing for integration with third-party applications, mobile apps, or custom scripts.

## Getting Started

The entire stack is designed to be easily deployed using Docker and Docker Compose.

### Prerequisites

*   **Docker:** [Installation Guide](https://docs.docker.com/engine/install/)
*   **Docker Compose:** [Installation Guide](https://docs.docker.com/compose/install/)

### Installation and Setup

1.  **Clone the Repository:**
    ```bash
    git clone https://github.com/algizzz/iot-sensor-logger.git
    cd iot-sensor-logger
    ```

2.  **Generate Environment File:**
    The project uses an `.env` file for all service configurations. A script is provided to generate this file with secure, random credentials.
    ```bash
    ./envgen.sh
    ```
    This will create a `.env` file from the `.env.example` template.

3.  **Run the Deployment Script:**
    The `deploy.sh` script automates the entire setup process.
    ```bash
    ./deploy.sh
    ```
    This script will:
    *   Validate that Docker and Docker Compose are installed.
    *   Create necessary directories (e.g., for data and logs) with the correct permissions.
    *   Configure firewall rules (if UFW is active).
    *   Build and launch all services using `docker compose up`.
    *   Set up MQTT users for Telegraf and sensor devices.

### Accessing Services

Once the stack is running, you can access the services at the following default ports:

*   **Grafana:** `http://<your_server_ip>:3000`
*   **InfluxDB:** `http://<your_server_ip>:8086`
*   **API Docs:** `http://<your_server_ip>:8000/docs`
*   **MQTT Broker:** `<your_server_ip>:1883`

### Managing the Services

You can manage the running services using standard Docker Compose commands:

*   **View service status:** `docker compose ps`
*   **View service logs:** `docker compose logs -f <service_name>` (e.g., `grafana`)
*   **Stop all services:** `docker compose down`

## Dashboards

The project includes a pre-built Grafana dashboard for visualizing sensor data.

### IoT Sensors Dashboard

This dashboard provides a comprehensive view of your sensor network, including:

*   **Time-series graphs:** For Temperature, Humidity, and Pressure.
*   **Device Status Table:** Shows which devices are currently `Online` or `Offline`.
*   **Last Seen Table:** Displays how long it has been since each device last reported data.

### Public Dashboard Setup

A utility script, `setup-public-dashboard.sh`, is included to automatically create a publicly accessible, read-only version of the main dashboard.

To create a public dashboard, run the following command:
```bash
./setup-public-dashboard.sh
```
The script will handle the necessary modifications to the dashboard configuration and generate a public URL, which will be saved to `public-dashboard-url.txt`.

## Device Firmware

The `firmware/` directory contains Arduino-compatible source code for ESP8266-based sensor devices. All firmware versions use the **WiFiManager** library, which creates a web portal for easy configuration of Wi-Fi and MQTT credentials without hardcoding them.

There are three versions of the firmware available:

1.  **`BME280_srv/`**
    *   **Description:** The standard firmware. It connects the device to Wi-Fi and MQTT, reads temperature, humidity, and pressure from a BME280 sensor, and publishes the data every 10 seconds.

2.  **`BME280_srv_sleep/`**
    *   **Description:** A power-optimized version that utilizes the ESP8266's deep sleep mode.
    *   **Functionality:** The device wakes up, reads and publishes the sensor data, and then enters deep sleep for 30 seconds to significantly reduce power consumption. Ideal for battery-powered devices.

3.  **`BME280_srv_sleep_upd/`**
    *   **Description:** This version adds **Over-the-Air (OTA)** update capabilities to the deep sleep firmware.
    *   **Functionality:** By holding a button during boot, the device enters "Update Mode." In this mode, it hosts a web server that allows you to upload a new firmware `.bin` file directly over the network, eliminating the need for a physical serial connection for updates.

## Development

### Configuration
All service configurations are managed through the `.env` file. No secrets or environment-specific values should be hardcoded.

### Security
*   The API is secured with a token-based authentication system.
*   The MQTT broker requires authentication.
*   Grafana is set up with an admin user and password.

### Hardware
The `hardware/` directory contains 3D models (`.stp`, `.m3d`) for a sensor enclosure and PCB design files (`.pcbdoc`, `.schdoc`) for a custom sensor board.
