# frozen_string_literal: true

require_relative "adventure_finder_ingest_operation_store"

module AdventureFinderWorkspace
  # Reuses the selected pipeline's public definition validator for durable AF
  # selection. No definitions are loaded for unselected historical operations.
  module EditorialSpecificationSelection
    # Bind an explicit absolute root using the pipeline owner. Returns its exact
    # JSON identity; missing code or invalid bytes raise Store::Failure.
    def self.bind!(root, pipeline_root:)
      require File.join(pipeline_root, "lib/af_data_pipeline/editorial_specifications")
      AfDataPipeline::EditorialSpecifications.bind!(root)
    rescue LoadError => error
      raise IngestOperationStore::Failure.new("EDITORIAL_SPECIFICATIONS_REFUSED", error.message)
    rescue AfDataPipeline::ValidationError => error
      raise IngestOperationStore::Failure.new("EDITORIAL_SPECIFICATIONS_REFUSED", error.message)
    end

    # Revalidate a retained identity without fallback or rebinding. Returns nil;
    # changed metadata or bytes raise Store::Failure.
    def self.validate!(binding, pipeline_root:)
      return unless binding

      unless binding == bind!(binding["root"], pipeline_root:)
        raise IngestOperationStore::Failure.new(
          "EDITORIAL_SPECIFICATIONS_REFUSED", "operation-bound public specification selection changed"
        )
      end
      nil
    end
  end
end
