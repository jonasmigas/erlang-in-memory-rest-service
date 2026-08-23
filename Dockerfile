FROM erlang:26-alpine

# Install build dependencies
RUN apk add --no-cache git build-base wget

# Install rebar3
RUN wget -O /usr/local/bin/rebar3 https://s3.amazonaws.com/rebar3/rebar3 \
    && chmod +x /usr/local/bin/rebar3 \
    && /usr/local/bin/rebar3 --version

# Set working directory
WORKDIR /app

# Copy rebar.config first (for dependency caching)
COPY rebar.config ./

# Fetch dependencies
RUN /usr/local/bin/rebar3 compile

# Copy source code
COPY src ./src

# Compile the application
RUN /usr/local/bin/rebar3 compile

# Expose the HTTP port
EXPOSE 8080

# Start the Erlang shell with the application
CMD ["/usr/local/bin/rebar3", "shell"]