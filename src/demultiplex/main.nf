workflow run_wf {
  take:
    input_ch

  main:
    samples_ch = input_ch
      // untar input if needed
      | untar.run(
        runIf: {id, state ->
          def inputStr = state.input.toString()
          inputStr.endsWith(".tar.gz") || \
          inputStr.endsWith(".tar") || \
          inputStr.endsWith(".tgz") ? true : false
        },
        fromState: [
          "input": "input",
        ],
        toState: { id, result, state ->
          def newState = state + ["input": result.output]
          newState
        },
      )
      // Gather input files from folder
      | map {id, state ->
        // Get InterOp folder
        // TODO: check if InterOp folder is empty
        def interop_files = files("${state.input}/InterOp/*.bin")
        // assert interop_files.size() > 0: "Could not find any InterOp files."
        println "Found InterOp files: ${interop_files}"
        def newState = state + ["interop_files": interop_files] 
        [id, newState]
      }

      // run bcl_convert
      | bcl_convert.run(
          fromState: { id, state ->
            [
              "bcl_input_directory": state.input,
              "sample_sheet": state.sample_sheet,
              "output_directory": "${state.output}",
            ]
          },
          toState: { id, result, state -> 
            state + [ "output_bclconvert" : result.output_directory ] 
          }
      )
      // Gather input files from BCL convert output folder
      | flatMap { id, state ->
        println "Processing sample sheet: $state.sample_sheet"
        def sample_sheet = file(state.sample_sheet.toAbsolutePath())
        def start_parsing = false
        def sample_id_column_index = null
        def samples = ["Undetermined"]
        def original_id = id
        
        // Gather reports file
        def report_dir = files("${state.output_bclconvert}/Reports", type: "dir")
        assert report_dir.size() == 1:
        "Could not the Reports directory in the output from BCL convert."
        report_dir = report_dir[0]

        // Parse sample sheet for sample IDs
        csv_lines = sample_sheet.splitCsv(header: false, sep: ',')
        csv_lines.any { csv_items ->
          if (csv_items.isEmpty()) {
            return
          }
          def possible_header = csv_items[0]
          def header = possible_header.find(/\[(.*)\]/){fullmatch, header_name -> header_name}
          if (header) {
            if (start_parsing) {
              // Stop parsing when encountering the next header
              return true
            }
            if (header == "Data") {
              start_parsing = true
            }
          }
          if (start_parsing) {
            if ( !sample_id_column_index ) {
              sample_id_column_index = csv_items.findIndexValues{it == "Sample_ID"}
              assert sample_id_column_index != -1: 
              "Could not find column 'Sample_ID' in sample sheet!"
              return
            }
            samples += csv_items[sample_id_column_index]
          }
        }
        println "Looking for fastq files in ${state.output_bclconvert}."
        def allfastqs = files("${state.output_bclconvert}/*.fastq.gz")
        println "Found ${allfastqs.size()} fastq files."
        processed_samples = samples.collect { sample_id ->
          def forward_glob = "${sample_id}_S[0-9]*_R1_00?.fastq.gz"
          def reverse_glob = "${sample_id}_S[0-9]*_R2_00?.fastq.gz"
          def forward_fastq = files("${state.output_bclconvert}/${forward_glob}", type: 'file')
          def reverse_fastq = files("${state.output_bclconvert}/${reverse_glob}", type: 'file')
          assert forward_fastq.size() < 2: 
          "Found multiple forward fastq files corresponding to sample ${sample_id}."
          assert reverse_fastq.size() < 2: 
          "Found multiple reverse fastq files corresponding to sample ${sample_id}."
          assert !forward_fastq.isEmpty(): 
          "Expected a forward fastq file to have been created correspondig to sample ${sample_id}."
          // TODO: if one sample had reverse reads, the others must as well.
          reverse_fastq = !reverse_fastq.isEmpty() ? reverse_fastq[0] : null
          def new_state = [
            "fastq_forward": forward_fastq[0],
            "fastq_reverse": reverse_fastq,
            "run_id": original_id,
            "bclconvert_reports": report_dir,
          ]
          [sample_id, new_state + state]
        }
        return processed_samples
      }

    output_ch = samples_ch
      // Going back to run-level, set the run ID back to the first element so we can use groupTuple
      // Using toSortedList will not work when multiple runs are being processed at the same time.
      | map { id, state ->
        def newEvent = [state.run_id, state + ["sample_id": id]]
        newEvent
      }
      | groupTuple(by: 0, sort: "hash")
    //   | map {run_id, states ->
    //     // Gather the following state for all samples
    //     def forward_fastqs = states.collect{it.fastq_forward}
    //     def reverse_fastqs = states.collect{it.fastq_reverse}.findAll{it != null}
    //     def sample_ids = states.collect{it.sample_id}
    //     // Other arguments should be the same for all samples, just pick the first
    //     // TODO: verify this
    //     def old_state = states[0]
    //     old_state.remove("sample_id")
        
    //     def keys_to_overwrite = [
    //       "forward_fastqs": forward_fastqs,
    //       "reverse_fastqs": reverse_fastqs,
    //       "sample_ids": sample_ids,
    //     ]
    //     return [run_id, old_state + keys_to_overwrite]
    //   }
    //   | falco.run(
    //     fromState: {id, state ->
    //       reverse_fastqs_list = state.reverse_fastqs ? state.reverse_fastqs : []
    //       [
    //         "input": state.forward_fastqs + reverse_fastqs_list,
    //         "outdir": "${state.output}/falco",
    //         "summary_filename": null,
    //         "report_filename": null,
    //         "data_filename": null,
    //       ]
    //     },
    //     toState: { id, result, state -> state + [ "output_falco" : result.outdir ] },
    //   )
    //   | multiqc.run(
    //     fromState: {id, state ->
    //       // Gather text files from Falco output directory
    //       falco_txt_output = files("$state.output_falco/*.txt", type: "file")
    //       ["input": falco_txt_output + state.interop_files]
    //     },
    //     toState: { id, result, state -> state + [ "output_multiqc" : result.outdir ] },
    //   )
    //   | setState(["output": "output_bclconvert", "output_falco": "output_falco", "output_multiqc": "output_multiqc"])

  emit:
    output_ch
}
