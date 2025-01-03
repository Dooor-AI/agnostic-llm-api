# Use an official Python base image
FROM python:3.9-slim

# Set the working directory inside the container
WORKDIR /app

# Copy all necessary files into the container
COPY . .

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        git \
        curl \
        && rm -rf /var/lib/apt/lists/*

# Install Rust (required for some Python dependencies)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y && \
    echo "export PATH=$HOME/.cargo/bin:\$PATH" >> /etc/profile

# Install Python dependencies
RUN pip install --upgrade pip setuptools-rust && \
    pip install -r requirements.txt

# Expose the port that the application will use
EXPOSE 8080

# Set the environment variable for the HF token
ENV HF_TOKEN=your_hf_token_here

# Command to start the application
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:8080", "--timeout", "6000", "app:app"]
