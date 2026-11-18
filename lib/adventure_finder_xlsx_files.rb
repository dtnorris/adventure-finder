# frozen_string_literal: true

require "pathname"

# Use the same public owner selector as the data pipeline.
module AdventureFinderWorkspace
  module XlsxFiles
    # Load API 0.1 from the selected absolute root or the Ruby load path.
    # Returns the owner module and raises LoadError if the selection is unusable.
    def self.load!
      root = ENV["AF_XLSX_FILES_ROOT"]
      if root
        unless Pathname.new(root).absolute?
          raise LoadError, "AF_XLSX_FILES_ROOT must be an absolute directory"
        end
        entry = File.join(root, "lib", "af_xlsx_files.rb")
        raise LoadError, "AF_XLSX_FILES_ROOT has no public entrypoint: #{entry}" unless File.file?(entry)
        owner_lib = File.realpath(File.dirname(entry)) + File::SEPARATOR
        entry = File.realpath(entry)
        raise LoadError, "af-xlsx-files entrypoint is outside the selected root" unless entry.start_with?(owner_lib)
        loaded = $LOADED_FEATURES.find { |path| path.end_with?("/af_xlsx_files.rb") }
        if loaded && File.realpath(loaded) != entry
          raise LoadError, "another af-xlsx-files owner is already loaded: #{loaded}"
        end
        require entry
        if $LOADED_FEATURES.any? { |path| path.include?("/af_xlsx_files/") && !File.realpath(path).start_with?(owner_lib) }
          raise LoadError, "af-xlsx-files loaded outside the selected root"
        end
      else
        require "af_xlsx_files"
      end
      unless defined?(AfXlsxFiles::API_VERSION) && AfXlsxFiles::API_VERSION == "0.1"
        raise LoadError, "af-xlsx-files API 0.1 is required"
      end
      AfXlsxFiles
    end
  end
end
