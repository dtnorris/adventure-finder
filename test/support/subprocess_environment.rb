# frozen_string_literal: true

# Keep the test process's activated bundle, but do not export it into fixture
# CLIs or independently bundled components. Restore the caller's Ruby options
# (including offline guards), PATH and gem paths using Bundler's own API.
ENV.replace(Bundler.unbundled_env) if defined?(Bundler)
