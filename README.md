# IoT Sensor Logger

## Project Overview

This project is a complete IoT sensor logging and monitoring stack. It is designed to collect, store, and expose sensor data from IoT devices. The architecture is based on a set of Docker containers that work together to provide a robust and scalable solution.

The main components of the stack are:

*   **Mosquitto:** An MQTT broker that serves as the entry point for sensor data. IoT devices publish their readings to specific MQTT topics.
*   **Telegraf:** A server-driven collector that subscribes to the MQTT topics, parses the incoming data, and writes it to InfluxDB.
*   **InfluxDB:** A high-performance time-series database that stores the sensor data.
*   **Grafana:** A leading open source platform for monitoring and observability. It allows you to query, visualize, alert on and understand your metrics no matter where they are stored.
*   **API (FastAPI):** A Python-based RESTful API that provides endpoints for querying the sensor data stored in InfluxDB. This allows for easy integration with dashboards, mobile apps, or other services.

## Building and Running

The project is designed to be run with Docker and Docker Compose.

### Prerequisites

*   Docker
*   Docker Compose

### Initial Setup

1.  **Generate the environment file:**

    The project uses an `.env` file to configure the services. You can generate a new `.env` file with secure, random credentials by running the `envgen.sh` script:

    ```bash
    ./envgen.sh
    ```

    This will create a `.env` file based on the `.env.example` template.

2.  **Bootstrap the environment (optional):**

    The `bootstrap.sh` script can be used to install Docker and clone the project repository. This is useful for setting up a new server from scratch.

    ```bash
    ./bootstrap.sh
    ```

### Running the Stack

To run the entire stack, use the `deploy.sh` script:

```bash
./deploy.sh
```

This script will:

1.  Read the configuration from the `.env` file.
2.  Check for dependencies like Docker and Docker Compose.
3.  Set up the necessary directories and permissions.
4.  Configure the firewall (if UFW is enabled).
5.  Build and start all the services using `docker-compose up`.
6.  Configure the MQTT users and passwords.

### Accessing Services

*   **Grafana:** `http://<your_server_ip>:3000`
*   **InfluxDB:** `http://<your_server_ip>:8086`
*   **API Docs:** `http://<your_server_ip>:8000/docs`
*   **MQTT:** `<your_server_ip>:1883`

### Managing the Services

Once the stack is running, you can manage the services using standard Docker Compose commands:

*   **View the status of the services:**
    ```bash
    docker compose ps
    ```
*   **View the logs of a specific service:**
    ```bash
    docker compose logs -f <service_name>
    ```
    (e.g., `docker compose logs -f grafana`)
*   **Stop the services:**
    ```bash
    docker compose down
    ```

## Development Conventions

*   **Configuration:** All configuration is managed through the `.env` file. No secrets or environment-specific values should be hardcoded in the source code.
*   **API:** The API is built with FastAPI and follows modern Python best practices. It includes dependency injection for security and a clear, well-documented structure.
*   **Data Flow:** The data flow is unidirectional: `IoT Device -> Mosquitto (MQTT) -> Telegraf -> InfluxDB -> Grafana / API`. This makes the system easy to reason about and debug.
*   **Security:** The API is protected by a token-based authentication system. The MQTT broker is configured to require authentication. Grafana is set up with an admin user and password.
