# frozen_string_literal: true

require "json"
require "pathname"
require "sinatra/base"
require "erb"

class CacheCleanerApp < Sinatra::Base
  enable :logging
  set :root, File.dirname(__FILE__)
  set :method_override, false
  set :protection, except: :path_traversal

  CACHE_DIR = Pathname.new(File.join(Dir.home, "ondemand/data/sys/dashboard/batch_connect/cache")).freeze
  CACHE_FILENAME_GLOBS = ["sys_*.json", "dev_*.json"].freeze
  CACHE_FILENAME_PATTERN = /\A(?:sys|dev)_[^\/]+\.json\z/.freeze
  RETURN_URL = ENV.fetch("OOD_RETURN_URL", "/pun/sys/dashboard").freeze

  class << self
    def available_cache_files
      return [] unless CACHE_DIR.directory?

      CACHE_FILENAME_GLOBS
        .flat_map { |glob| Dir.glob(CACHE_DIR.join(glob).to_s) }
        .uniq
        .select { |path| File.file?(path) && !File.symlink?(path) }
        .sort_by { |path| File.basename(path).downcase }
        .map do |path|
          filename = File.basename(path)
          {
            filename: filename,
            label: friendly_label(filename)
          }
        end
    end

    def friendly_label(filename)
      base = filename.sub(/\A(?:sys|dev)_/, "").sub(/\.json\z/, "")
      normalized = base.include?("_") ? base.split("_", 2).last : base
      normalized.tr("_", " ")
    end

    def whitelisted_filename?(filename)
      available_cache_files.any? { |entry| entry[:filename] == filename }
    end

    def safe_cache_path(filename)
      return nil unless filename.is_a?(String)
      return nil unless CACHE_FILENAME_GLOBS.any? { |glob| File.fnmatch?(glob, filename, File::FNM_PATHNAME) }
      return nil unless filename.match?(CACHE_FILENAME_PATTERN)
      return nil unless whitelisted_filename?(filename)

      expanded = CACHE_DIR.join(filename).expand_path

      return nil unless expanded.dirname == CACHE_DIR.expand_path
      return nil unless expanded.exist?

      stat = File.lstat(expanded.to_s)
      return nil unless stat.file?
      return nil if stat.symlink?

      expanded
    rescue Errno::ENOENT, Errno::ENOTDIR
      nil
    end
  end

  def h(value)
    Rack::Utils.escape_html(value.to_s)
  end

  def sanitize_return_url(value)
    return nil unless value.is_a?(String)
    return nil if value.empty?
    return nil unless value.start_with?("/pun/")
    return nil if value.include?("://")

    value
  end

  def resolved_return_url
    sanitize_return_url(params["return_url"]) ||
      sanitize_return_url(request.referer&.sub(%r{\Ahttps?://[^/]+}, "")) ||
      RETURN_URL
  end

  def fresh_return_url
    url = resolved_return_url
    path, fragment = url.split("#", 2)
    base, query = path.split("?", 2)
    params = Rack::Utils.parse_nested_query(query.to_s)
    params["cache_reset"] = "1"
    params["cache_reset_at"] = Time.now.to_i.to_s
    rebuilt = base
    encoded = Rack::Utils.build_query(params)
    rebuilt += "?#{encoded}" unless encoded.empty?
    rebuilt += "##{fragment}" if fragment
    rebuilt
  end

  def current_env_name
    if (match = request.path_info.to_s.match(%r{/pun/([^/]+)/}))
      match[1]
    else
      nil
    end
  end

  def preferred_cache_file
    requested = params["cache_file"].to_s
    return requested unless requested.empty?

    app_slug = params["app_slug"].to_s
    return "" if app_slug.empty?

    env_prefix = current_env_name == "dev" ? "dev" : "sys"
    preferred = "#{env_prefix}_#{app_slug}.json"
    return preferred if self.class.whitelisted_filename?(preferred)

    fallback = self.class.available_cache_files.find { |entry| entry[:filename].end_with?("_#{app_slug}.json") }
    fallback ? fallback[:filename] : ""
  end

  def render_index_page(status: nil, message: nil)
    cache_files = self.class.available_cache_files
    base_path = current_base_path.sub(%r{/\z}, "")
    clear_path = "#{base_path}/clear"
    selected_file = preferred_cache_file
    return_url = resolved_return_url
    options_html = cache_files.map do |entry|
      filename = h(entry[:filename])
      label = h("#{entry[:label]} (#{entry[:filename]})")
      selected_attr = entry[:filename] == selected_file ? ' selected="selected"' : ""
      %(<option value="#{filename}"#{selected_attr}>#{label}</option>)
    end.join("\n")

    status_html = if status && message
      %(<div class="status #{h(status)}">#{h(message)}</div>)
    else
      ""
    end

    helper_copy = if cache_files.empty?
      "No matching cache files are currently available for this account."
    else
      "#{cache_files.length} cache #{cache_files.length == 1 ? "file" : "files"} available for this account."
    end

    body_html = if cache_files.empty?
      %(<div class="status warning">No cache files matching <code>sys_*.json</code> or <code>dev_*.json</code> were found in <code>#{h(CACHE_DIR.to_s)}</code>.</div>)
    else
      <<~HTML
        <form action="#{h(clear_path)}" method="post">
          <div class="field-header">
            <label for="cache_file">Choose an app cache</label>
            <p>Pick the saved form state you want to remove. This only affects your own Open OnDemand cache.</p>
          </div>
          <select id="cache_file" name="cache_file" required>
            #{options_html}
          </select>
          <input type="hidden" name="app_slug" value="#{h(params["app_slug"])}">
          <input type="hidden" name="return_url" value="#{h(return_url)}">

          <div class="actions">
            <button type="submit">Clear cache</button>
            <button type="submit" name="return_after" value="1" class="secondary">Clear and return</button>
            <a class="link-button secondary" href="#{h(return_url)}">Back</a>
          </div>
        </form>
      HTML
    end

    <<~HTML
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Reset Saved Form Values</title>
          <style>
            :root {
              color-scheme: light;
              --bg: #f5f7f4;
              --panel: #ffffff;
              --text: #1d2a21;
              --muted: #5d6b62;
              --border: #cfd8d1;
              --accent: #1e5d3b;
              --success-bg: #e8f5eb;
              --success-text: #174b27;
              --warning-bg: #fff4db;
              --warning-text: #7a5b00;
              --error-bg: #fde8e8;
              --error-text: #8a1c1c;
            }

            * { box-sizing: border-box; }
            body {
              margin: 0;
              padding: 3rem 1.5rem;
              background: linear-gradient(180deg, #eef3ec 0%, var(--bg) 100%);
              color: var(--text);
              font-family: "IBM Plex Sans", "Helvetica Neue", Helvetica, Arial, sans-serif;
            }

            .panel {
              max-width: 56.7rem;
              margin: 0 auto;
              background: var(--panel);
              border: 1px solid var(--border);
              border-radius: 12px;
              padding: 2.25rem;
              box-shadow: 0 10px 30px rgba(19, 45, 29, 0.08);
            }

            h1 {
              margin-top: 0;
              margin-bottom: 0.5rem;
              font-size: 1.6rem;
            }

            p {
              color: var(--muted);
              line-height: 1.5;
            }

            label {
              display: block;
              margin-top: 1rem;
              margin-bottom: 0.35rem;
              font-weight: 600;
            }

            select {
              width: 100%;
              padding: 0.7rem 0.8rem;
              border: 1px solid var(--border);
              border-radius: 8px;
              background: #fff;
              color: var(--text);
              font-size: 1rem;
            }

            .actions {
              display: flex;
              flex-wrap: wrap;
              gap: 0.75rem;
              margin-top: 1.25rem;
            }

            button, .link-button {
              display: inline-block;
              padding: 0.75rem 1rem;
              border-radius: 8px;
              border: 1px solid var(--accent);
              background: var(--accent);
              color: #fff;
              font-size: 0.95rem;
              font-weight: 600;
              text-decoration: none;
              cursor: pointer;
            }

            button.secondary, .link-button.secondary {
              background: #fff;
              color: var(--accent);
            }

            .status {
              margin-top: 1rem;
              padding: 0.9rem 1rem;
              border-radius: 8px;
              border: 1px solid transparent;
            }

            .status.success {
              background: var(--success-bg);
              color: var(--success-text);
              border-color: #b8ddc1;
            }

            .status.warning {
              background: var(--warning-bg);
              color: var(--warning-text);
              border-color: #eedaa0;
            }

            .status.error {
              background: var(--error-bg);
              color: var(--error-text);
              border-color: #f4baba;
            }

            .meta {
              margin-top: 2.25rem;
              padding-top: 1.875rem;
              border-top: 1px solid var(--border);
            }

            .meta-grid {
              display: grid;
              grid-template-columns: minmax(9rem, 11rem) 1fr;
              gap: 0.4rem 1rem;
              align-items: start;
              font-size: 0.96rem;
            }

            .meta-label {
              color: var(--muted);
              font-weight: 600;
            }

            .meta-value code {
              font-size: 0.92rem;
              word-break: break-all;
            }

            .eyebrow {
              display: inline-flex;
              align-items: center;
              gap: 0.5rem;
              padding: 0.35rem 0.65rem;
              border-radius: 999px;
              background: #e7efe9;
              color: var(--accent);
              font-size: 0.82rem;
              font-weight: 700;
              letter-spacing: 0.04em;
              text-transform: uppercase;
            }

            .field-header {
              margin-top: 1.25rem;
              margin-bottom: 0.5rem;
            }

            .field-header p {
              margin: 0.3rem 0 0;
              font-size: 0.96rem;
            }

            .helper {
              margin-top: 0.75rem;
              margin-bottom: 0;
              font-size: 0.92rem;
            }

            @media (max-width: 640px) {
              body {
                padding: 1rem 0.75rem;
              }

              .panel {
                padding: 1rem;
              }

              .actions {
                flex-direction: column;
              }

              button, .link-button {
                width: 100%;
                text-align: center;
              }

              .meta-grid {
                grid-template-columns: 1fr;
                gap: 0.2rem;
              }
            }
          </style>
        </head>
        <body>
          <main class="panel">
            <div class="eyebrow">Open OnDemand Utility</div>
            <h1>Reset Saved Form Values</h1>
            #{status_html}
            #{body_html}
            <p class="helper">#{h(helper_copy)}</p>
            <p class="meta">
              <span class="meta-grid">
                <span class="meta-label">Cache directory</span>
                <span class="meta-value"><code>#{h(CACHE_DIR.to_s)}</code></span>
                <span class="meta-label">Allowed pattern</span>
                <span class="meta-value"><code>#{h(CACHE_FILENAME_GLOBS.join(", "))}</code></span>
              </span>
            </p>
          </main>
        </body>
      </html>
    HTML
  end

  def current_base_path
    script = request.script_name.to_s
    return script unless script.empty?

    path = request.path_info.to_s
    return path.sub(%r{/clear/?\z}, "") if path.end_with?("/clear")
    return path if path.end_with?("/")

    path
  end

  get "/" do
    render_index_page(status: params["status"], message: params["message"])
  end

  get "/pun/:env/cache_reset/?" do
    render_index_page(status: params["status"], message: params["message"])
  end

  post "/clear" do
    selected_file = params["cache_file"].to_s
    return_after = params["return_after"] == "1"
    base_path = current_base_path
    return_url = resolved_return_url

    cache_path = self.class.safe_cache_path(selected_file)

    if cache_path.nil?
      redirect to("#{base_path}/?status=error&message=#{Rack::Utils.escape("Invalid or unavailable cache file selection.")}&return_url=#{Rack::Utils.escape(return_url)}&cache_file=#{Rack::Utils.escape(selected_file)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
    end

    begin
      File.delete(cache_path.to_s)
      success_message = "Deleted cache file #{selected_file}."

      if return_after
        redirect fresh_return_url
      else
        redirect to("#{base_path}/?status=success&message=#{Rack::Utils.escape(success_message)}&return_url=#{Rack::Utils.escape(return_url)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
      end
    rescue Errno::ENOENT
      redirect to("#{base_path}/?status=warning&message=#{Rack::Utils.escape("Cache file was already removed.")}&return_url=#{Rack::Utils.escape(return_url)}&cache_file=#{Rack::Utils.escape(selected_file)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
    rescue StandardError => e
      logger.error("Failed to delete cache file #{selected_file}: #{e.class}: #{e.message}")
      redirect to("#{base_path}/?status=error&message=#{Rack::Utils.escape("Failed to delete the selected cache file.")}&return_url=#{Rack::Utils.escape(return_url)}&cache_file=#{Rack::Utils.escape(selected_file)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
    end
  end

  post "/pun/:env/cache_reset/clear" do
    selected_file = params["cache_file"].to_s
    return_after = params["return_after"] == "1"
    base_path = current_base_path.sub(%r{/clear\z}, "")
    return_url = resolved_return_url

    cache_path = self.class.safe_cache_path(selected_file)

    if cache_path.nil?
      redirect to("#{base_path}/?status=error&message=#{Rack::Utils.escape("Invalid or unavailable cache file selection.")}&return_url=#{Rack::Utils.escape(return_url)}&cache_file=#{Rack::Utils.escape(selected_file)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
    end

    begin
      File.delete(cache_path.to_s)
      success_message = "Deleted cache file #{selected_file}."

      if return_after
        redirect fresh_return_url
      else
        redirect to("#{base_path}/?status=success&message=#{Rack::Utils.escape(success_message)}&return_url=#{Rack::Utils.escape(return_url)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
      end
    rescue Errno::ENOENT
      redirect to("#{base_path}/?status=warning&message=#{Rack::Utils.escape("Cache file was already removed.")}&return_url=#{Rack::Utils.escape(return_url)}&cache_file=#{Rack::Utils.escape(selected_file)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
    rescue StandardError => e
      logger.error("Failed to delete cache file #{selected_file}: #{e.class}: #{e.message}")
      redirect to("#{base_path}/?status=error&message=#{Rack::Utils.escape("Failed to delete the selected cache file.")}&return_url=#{Rack::Utils.escape(return_url)}&cache_file=#{Rack::Utils.escape(selected_file)}&app_slug=#{Rack::Utils.escape(params["app_slug"].to_s)}")
    end
  end
end
