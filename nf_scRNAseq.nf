
#!/usr/bin/env nextflow

/*
 * Single-Cell RNA-seq Analysis Pipeline with Cell Ranger and Seurat
 * Author: NikGiannak
 * Version: 1.1.0
 */

nextflow.enable.dsl = 2

// Pipeline parameters
params {
    // Input parameters
    input_dir = null
    samplesheet = null
    fastq_dir = null
    
    // Reference genome
    reference_genome = null
    
    // Cell Ranger parameters
    expect_cells = 5000
    localcores = 8
    localmem = 64
    chemistry = "auto"
    
    // Analysis parameters
    min_cells = 3
    min_features = 200
    max_features = 5000
    max_mt_percent = 20
    min_umi = 500
    max_umi = 25000
    resolution = 0.5
    n_variable_features = 2000
    
    // Output directory
    outdir = "./results"
    
    // Resource parameters
    max_memory = '128.GB'
    max_cpus = 16
    max_time = '240.h'
    
    // Skip steps
    skip_cellranger = false
    skip_seurat = false
    skip_integration = false
    
    // Help
    help = false
}

// Help message
def helpMessage() {
    log.info"""
    Single-Cell RNA-seq Analysis Pipeline
    =====================================
    
    Usage:
    nextflow run main.nf --samplesheet samples.csv --reference_genome /path/to/reference --outdir results
    
    Required Arguments:
      --samplesheet         Path to sample sheet CSV file
      --reference_genome    Path to Cell Ranger reference genome directory
      --outdir             Output directory for results
    
    Optional Arguments:
      --fastq_dir          Directory containing FASTQ files (if not in samplesheet)
      --expect_cells       Expected number of cells per sample (default: 5000)
      --localcores         Number of cores for Cell Ranger (default: 8)
      --localmem           Memory in GB for Cell Ranger (default: 64)
      --chemistry          Chemistry version for Cell Ranger (default: auto)
      --resolution         Clustering resolution for Seurat (default: 0.5)
      --skip_cellranger    Skip Cell Ranger processing
      --skip_seurat        Skip Seurat analysis
      --skip_integration   Skip sample integration
      --help               Show this help message
    
    Sample Sheet Format:
      sample_id,fastq_path,sample_name,condition
      Sample1,/path/to/fastqs,Sample1,Control
      Sample2,/path/to/fastqs,Sample2,Treatment
    """.stripIndent()
}

// Show help message
if (params.help) {
    helpMessage()
    exit 0
}

// Parameter validation
if (!params.samplesheet) {
    error "Please provide a sample sheet with --samplesheet"
}

if (!params.reference_genome) {
    error "Please provide a reference genome with --reference_genome"
}

if (!file(params.samplesheet).exists()) {
    error "Sample sheet file not found: ${params.samplesheet}"
}

if (!file(params.reference_genome).exists()) {
    error "Reference genome directory not found: ${params.reference_genome}"
}

/*
 * WORKFLOW DEFINITION
 */

workflow {
    // Parse sample sheet
    ch_samples = parse_samplesheet(params.samplesheet)
    
    // Cell Ranger workflow
    if (!params.skip_cellranger) {
        CELLRANGER_COUNT(ch_samples, params.reference_genome)
        ch_cellranger_results = CELLRANGER_COUNT.out.results
        ch_metrics = CELLRANGER_COUNT.out.metrics
    } else {
        // If skipping Cell Ranger, assume results already exist
        ch_cellranger_results = ch_samples.map { sample ->
            def result_dir = file("${params.outdir}/cellranger/${sample.sample_id}")
            [sample, result_dir]
        }
        ch_metrics = Channel.empty()
    }
    
    // Seurat analysis workflow
    if (!params.skip_seurat) {
        // Individual sample analysis
        SEURAT_QC_AND_FILTER(ch_cellranger_results)
        ch_filtered_objects = SEURAT_QC_AND_FILTER.out.filtered_objects
        ch_qc_plots = SEURAT_QC_AND_FILTER.out.qc_plots
        
        // Integration (if multiple samples and not skipped)
        if (!params.skip_integration) {
            ch_all_samples = ch_filtered_objects.collect()
            SEURAT_INTEGRATION(ch_all_samples)
            ch_integrated = SEURAT_INTEGRATION.out.integrated_object
            
            // Downstream analysis on integrated data
            SEURAT_CLUSTERING(ch_integrated)
            SEURAT_MARKERS(SEURAT_CLUSTERING.out.clustered_object)
            SEURAT_VISUALIZATION(SEURAT_CLUSTERING.out.clustered_object, SEURAT_MARKERS.out.markers)
        } else {
            // Process each sample individually
            SEURAT_CLUSTERING(ch_filtered_objects)
            SEURAT_MARKERS(SEURAT_CLUSTERING.out.clustered_object)
            SEURAT_VISUALIZATION(SEURAT_CLUSTERING.out.clustered_object, SEURAT_MARKERS.out.markers)
        }
    }
    
    // Generate final report
    if (!params.skip_cellranger && !params.skip_seurat) {
        GENERATE_REPORT(
            ch_metrics.collect(),
            ch_qc_plots.collect(),
            SEURAT_VISUALIZATION.out.plots.collect()
        )
    }
}

/*
 * FUNCTIONS
 */

def parse_samplesheet(samplesheet_path) {
    return Channel
        .fromPath(samplesheet_path)
        .splitCsv(header: true)
        .map { row ->
            def sample = [:]
            sample.sample_id = row.sample_id
            sample.fastq_path = row.fastq_path ?: params.fastq_dir
            sample.sample_name = row.sample_name ?: row.sample_id
            sample.condition = row.condition ?: "Unknown"
            return sample
        }
}

/*
 * PROCESSES
 */

process CELLRANGER_COUNT {
    tag "$sample.sample_id"
    label 'process_high'
    publishDir "${params.outdir}/cellranger", mode: 'copy'
    
    input:
    val sample
    path reference_genome
    
    output:
    tuple val(sample), path("${sample.sample_id}"), emit: results
    path "${sample.sample_id}/outs/metrics_summary.csv", emit: metrics
    
    script:
    """
    cellranger count \\
        --id=${sample.sample_id} \\
        --transcriptome=${reference_genome} \\
        --fastqs=${sample.fastq_path} \\
        --sample=${sample.sample_id} \\
        --expect-cells=${params.expect_cells} \\
        --localcores=${params.localcores} \\
        --localmem=${params.localmem} \\
        --chemistry=${params.chemistry} \\
        --disable-ui
    """
}

process SEURAT_QC_AND_FILTER {
    tag "$sample.sample_id"
    label 'process_medium'
    publishDir "${params.outdir}/seurat/qc", mode: 'copy'
    
    input:
    tuple val(sample), path(cellranger_results)
    
    output:
    tuple val(sample), path("${sample.sample_id}_filtered.rds"), emit: filtered_objects
    path "${sample.sample_id}_qc_plots.pdf", emit: qc_plots
    
    script:
    """
    #!/usr/bin/env Rscript
    
    library(Seurat)
    library(dplyr)
    library(ggplot2)
    library(patchwork)
    
    # Load 10X data
    data <- Read10X(data.dir = "${cellranger_results}/outs/filtered_feature_bc_matrix")
    
    # Create Seurat object
    seurat_obj <- CreateSeuratObject(
        counts = data,
        project = "${sample.sample_id}",
        min.cells = ${params.min_cells},
        min.features = ${params.min_features}
    )
    
    # Add metadata
    seurat_obj\$sample <- "${sample.sample_id}"
    seurat_obj\$condition <- "${sample.condition}"
    
    # Calculate QC metrics
    seurat_obj[["percent.mt"]] <- PercentageFeatureSet(seurat_obj, pattern = "^MT-")
    seurat_obj[["percent.ribo"]] <- PercentageFeatureSet(seurat_obj, pattern = "^RP[SL]")
    
    # Create QC plots
    p1 <- VlnPlot(seurat_obj, features = c("nFeature_RNA", "nCount_RNA", "percent.mt"), ncol = 3)
    p2 <- FeatureScatter(seurat_obj, feature1 = "nCount_RNA", feature2 = "percent.mt")
    p3 <- FeatureScatter(seurat_obj, feature1 = "nCount_RNA", feature2 = "nFeature_RNA")
    
    combined_plot <- p1 / (p2 | p3)
    ggsave("${sample.sample_id}_qc_plots.pdf", combined_plot, width = 15, height = 10)
    
    # Filter cells
    filtered_obj <- subset(seurat_obj,
        subset = nFeature_RNA > ${params.min_features} &
                nFeature_RNA < ${params.max_features} &
                percent.mt < ${params.max_mt_percent} &
                nCount_RNA > ${params.min_umi} &
                nCount_RNA < ${params.max_umi}
    )
    
    cat("Original cells:", ncol(seurat_obj), "\\n")
    cat("Filtered cells:", ncol(filtered_obj), "\\n")
    
    # Save filtered object
    saveRDS(filtered_obj, "${sample.sample_id}_filtered.rds")
    """
}

process SEURAT_INTEGRATION {
    label 'process_high'
    publishDir "${params.outdir}/seurat/integration", mode: 'copy'
    
    input:
    path filtered_objects
    
    output:
    path "integrated_seurat.rds", emit: integrated_object
    
    script:
    """
    #!/usr/bin/env Rscript
    
    library(Seurat)
    library(dplyr)
    
    # Load all filtered objects
    object_files <- list.files(pattern = "_filtered.rds")
    seurat_list <- lapply(object_files, readRDS)
    names(seurat_list) <- gsub("_filtered.rds", "", object_files)
    
    if (length(seurat_list) > 1) {
        # Normalize and find variable features
        seurat_list <- lapply(seurat_list, function(x) {
            x <- NormalizeData(x)
            x <- FindVariableFeatures(x, selection.method = "vst", nfeatures = ${params.n_variable_features})
            return(x)
        })
        
        # Find integration anchors
        anchors <- FindIntegrationAnchors(object.list = seurat_list, dims = 1:30)
        
        # Integrate data
        integrated <- IntegrateData(anchorset = anchors, dims = 1:30)
        DefaultAssay(integrated) <- "integrated"
        
    } else {
        # Single sample
        integrated <- seurat_list[[1]]
        integrated <- NormalizeData(integrated)
        integrated <- FindVariableFeatures(integrated, selection.method = "vst", 
                                         nfeatures = ${params.n_variable_features})
    }
    
    # Save integrated object
    saveRDS(integrated, "integrated_seurat.rds")
    """
}

process SEURAT_CLUSTERING {
    tag "$sample_info"
    label 'process_medium'
    publishDir "${params.outdir}/seurat/clustering", mode: 'copy'
    
    input:
    tuple val(sample), path(seurat_object)
    
    output:
    tuple val(sample), path("*_clustered.rds"), emit: clustered_object
    
    script:
    sample_info = sample ? sample.sample_id : "integrated"
    """
    #!/usr/bin/env Rscript
    
    library(Seurat)
    
    # Load Seurat object
    seurat_obj <- readRDS("${seurat_object}")
    
    # Scale data and run PCA
    seurat_obj <- ScaleData(seurat_obj)
    seurat_obj <- RunPCA(seurat_obj, features = VariableFeatures(object = seurat_obj))
    
    # Determine number of PCs
    pct <- seurat_obj[["pca"]]@stdev / sum(seurat_obj[["pca"]]@stdev) * 100
    cumu <- cumsum(pct)
    co1 <- which(cumu > 90 & pct < 5)[1]
    co2 <- sort(which((pct[1:length(pct) - 1] - pct[2:length(pct)]) > 0.1), decreasing = T)[1] + 1
    pcs <- min(co1, co2, 30)
    
    # Clustering
    seurat_obj <- FindNeighbors(seurat_obj, dims = 1:pcs)
    seurat_obj <- FindClusters(seurat_obj, resolution = ${params.resolution})
    
    # UMAP and tSNE
    seurat_obj <- RunUMAP(seurat_obj, dims = 1:pcs)
    seurat_obj <- RunTSNE(seurat_obj, dims = 1:pcs)
    
    # Save clustered object
    saveRDS(seurat_obj, "${sample_info}_clustered.rds")
    """
}

process SEURAT_MARKERS {
    tag "$sample_info"
    label 'process_high'
    publishDir "${params.outdir}/seurat/markers", mode: 'copy'
    
    input:
    tuple val(sample), path(clustered_object)
    
    output:
    tuple val(sample), path("*_markers.csv"), emit: markers
    
    script:
    sample_info = sample ? sample.sample_id : "integrated"
    """
    #!/usr/bin/env Rscript
    
    library(Seurat)
    library(dplyr)
    
    # Load clustered object
    seurat_obj <- readRDS("${clustered_object}")
    
    # Set assay to RNA for marker detection
    DefaultAssay(seurat_obj) <- "RNA"
    
    # Find all markers
    all_markers <- FindAllMarkers(seurat_obj, 
                                 only.pos = TRUE, 
                                 min.pct = 0.25, 
                                 logfc.threshold = 0.25)
    
    # Save markers
    write.csv(all_markers, "${sample_info}_markers.csv", row.names = FALSE)
    """
}

process SEURAT_VISUALIZATION {
    tag "$sample_info"
    label 'process_medium'
    publishDir "${params.outdir}/seurat/plots", mode: 'copy'
    
    input:
    tuple val(sample), path(clustered_object)
    tuple val(sample_markers), path(markers_file)
    
    output:
    path "*.pdf", emit: plots
    
    script:
    sample_info = sample ? sample.sample_id : "integrated"
    """
    #!/usr/bin/env Rscript
    
    library(Seurat)
    library(ggplot2)
    library(dplyr)
    library(patchwork)
    
    # Load data
    seurat_obj <- readRDS("${clustered_object}")
    markers <- read.csv("${markers_file}")
    
    # UMAP plots
    p1 <- DimPlot(seurat_obj, reduction = "umap", label = TRUE, pt.size = 0.5) + 
          ggtitle("Clusters")
    
    if ("sample" %in% colnames(seurat_obj@meta.data)) {
        p2 <- DimPlot(seurat_obj, reduction = "umap", group.by = "sample", pt.size = 0.5) + 
              ggtitle("Samples")
        umap_combined <- p1 | p2
    } else {
        umap_combined <- p1
    }
    
    ggsave("${sample_info}_umap_plots.pdf", umap_combined, width = 16, height = 8)
    
    # Feature plots for top markers
    if (nrow(markers) > 0) {
        top_markers <- markers %>% 
            group_by(cluster) %>% 
            top_n(n = 2, wt = avg_log2FC) %>% 
            head(9)
        
        if (nrow(top_markers) > 0) {
            feature_plot <- FeaturePlot(seurat_obj, features = top_markers\$gene, ncol = 3)
            ggsave("${sample_info}_feature_plots.pdf", feature_plot, width = 15, height = 15)
        }
        
        # Heatmap of top markers
        top5_markers <- markers %>% 
            group_by(cluster) %>% 
            top_n(n = 5, wt = avg_log2FC)
        
        if (nrow(top5_markers) > 0) {
            heatmap_plot <- DoHeatmap(seurat_obj, features = top5_markers\$gene) + 
                           theme(axis.text.y = element_text(size = 6))
            ggsave("${sample_info}_heatmap.pdf", heatmap_plot, width = 15, height = 12)
        }
    }
    
    # QC by cluster
    qc_plot <- VlnPlot(seurat_obj, features = c("nFeature_RNA", "nCount_RNA", "percent.mt"), 
                       ncol = 3, pt.size = 0)
    ggsave("${sample_info}_qc_by_cluster.pdf", qc_plot, width = 15, height = 8)
    """
}

process GENERATE_REPORT {
    label 'process_low'
    publishDir "${params.outdir}/report", mode: 'copy'
    
    input:
    path metrics_files
    path qc_plots
    path analysis_plots
    
    output:
    path "pipeline_report.html"
    
    script:
    """
    #!/usr/bin/env Rscript
    
    library(rmarkdown)
    library(knitr)
    
    # Create report template
    report_template <- '
    ---
    title: "Single-Cell RNA-seq Analysis Report"
    date: "`r Sys.Date()`"
    output: 
      html_document:
        toc: true
        toc_float: true
        theme: bootstrap
    ---
    
    # Pipeline Summary
    
    This report summarizes the results of the single-cell RNA-seq analysis pipeline.
    
    ## Parameters Used
    - Expected cells per sample: ${params.expect_cells}
    - Clustering resolution: ${params.resolution}
    - Min features per cell: ${params.min_features}
    - Max mitochondrial percentage: ${params.max_mt_percent}
    
    ## Sample Metrics
    
    ```{r metrics, echo=FALSE}
    # Load and display metrics
    metrics_files <- list.files(pattern = "metrics_summary.csv", full.names = TRUE)
    if (length(metrics_files) > 0) {
      metrics_list <- lapply(metrics_files, read.csv)
      names(metrics_list) <- gsub("_metrics_summary.csv", "", basename(metrics_files))
      print("Sample processing completed successfully")
    }
    ```
    
    ## Analysis Results
    
    Analysis plots and results are available in the respective output directories.
    
    '
    
    # Write template
    writeLines(report_template, "report.Rmd")
    
    # render report
    render("report.Rmd", output_file = "pipeline_report.html")
    """
}
