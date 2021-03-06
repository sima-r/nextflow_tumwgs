#!/usr/bin/env nextflow

// GENERAL PATHS //
OUTDIR = params.outdir+'/'+params.subdir
CRONDIR = params.crondir

// SENTIEON CONFIGS //
K_size      = 100000000
bwa_num_shards = params.bwa_shards
bwa_shards = Channel.from( 0..bwa_num_shards-1 )
genomic_num_shards = params.genomic_shards_num

// FASTA //
genome_file = params.genome_file

// VEP REFERENCES AND ANNOTATION DBS //
CADD = params.CADD
VEP_FASTA = params.VEP_FASTA
MAXENTSCAN = params.MAXENTSCAN
VEP_CACHE = params.VEP_CACHE
GNOMAD = params.GNOMAD
GERP = params.GERP
PHYLOP =  params.PHYLOP
PHASTCONS = params.PHASTCONS

// ANNOTATION DBS GENERAL //
CLINVAR = params.CLINVAR


PON = [F: params.GATK_PON_FEMALE, M: params.GATK_PON_MALE]

group_id = "HEJ"

csv = file(params.csv)
mode = csv.countLines() > 2 ? "paired" : "unpaired"
println(mode)

Channel
    .fromPath(params.csv)
    .splitCsv(header:true)
    .map{ row-> tuple(row.group, row.id, file(row.read1), file(row.read2)) }
    .into { fastq_sharded; fastq; vcf_info }

Channel
    .fromPath(params.csv)
    .splitCsv(header:true)
    .map{ row-> tuple(row.id, row.diagnosis, row.read1, row.read2) }
    .set{ qc_extra }

Channel
    .fromPath(params.csv)
    .splitCsv(header:true)
    .map{ row-> tuple(row.group, row.id, row.sex, row.mother, row.father, row.phenotype, row.diagnosis) }
    .set { meta_gatkcov }


// Split bed file in to smaller parts to be used for parallel variant calling
Channel
    .fromPath("${params.intersect_bed}")
    .ifEmpty { exit 1, "Regions bed file not found: ${params.intersect_bed}" }
    .splitText( by: 20000, file: 'bedpart.bed' )
    .into { beds_freebayes; beds_vardict }



if(genome_file ){
    bwaId = Channel
            .fromPath("${genome_file}.bwt")
            .ifEmpty { exit 1, "BWA index not found: ${genome_file}.bwt" }
}


Channel
    .fromPath(params.genomic_shards_file)
    .splitCsv(header:false)
    .into { shards1; shards2; shards3; shards4; shards5; }

// A channel to pair neighbouring bams and vcfs. 0 and top value removed later
// Needs to be 0..n+1 where n is number of shards in shards.csv
Channel
    .from( 0..(genomic_num_shards+1) )
    .collate( 3,1, false )
    .into{ shardie1; shardie2 }


// Align fractions of fastq files with BWA
process bwa_align_sharded {
	cpus 50
	memory '64 GB'

	input:
		set val(shard), val(group), val(id), r1, r2 from bwa_shards.combine(fastq_sharded)

	output:
		set val(id), file("${id}_${shard}.bwa.sort.bam"), file("${id}_${shard}.bwa.sort.bam.bai") into bwa_shards_ch

	when:
		params.shardbwa

	"""
	sentieon bwa mem -M \\
		-R '@RG\\tID:${id}\\tSM:${id}\\tPL:illumina' \\
		-K $K_size \\
		-t ${task.cpus} \\
		-p $genome_file '<sentieon fqidx extract -F $shard/$bwa_num_shards -K $K_size $r1 $r2' | sentieon util sort \\
		-r $genome_file \\
		-o ${id}_${shard}.bwa.sort.bam \\
		-t ${task.cpus} --sam2bam -i -
	"""
}

// Merge the fractioned bam files
process bwa_merge_shards {
	cpus 50

	input:
		set val(id), file(shard), file(shard_bai) from bwa_shards_ch.groupTuple()

	output:
		set id, file("${id}_merged.bam"), file("${id}_merged.bam.bai") into merged_bam, qc_merged_bam

	when:
		params.shardbwa
    
	script:
		bams = shard.sort(false) { a, b -> a.getBaseName() <=> b.getBaseName() } .join(' ')

	"""
	sentieon util merge -o ${id}_merged.bam ${bams}
	"""
}

// ALTERNATIVE PATH: Unsharded BWA, utilize local scratch space.
process bwa_align {
	cpus 27
	memory '64 GB'
	scratch true
	stageInMode 'copy'
	stageOutMode 'copy'

	input:
		set val(group), val(id), file(r1), file(r2) from fastq

	output:
		set id, file("${id}_merged.bam"), file("${id}_merged.bam.bai") into bam, qc_bam

	when:
		!params.shardbwa

	"""
	sentieon bwa mem \\
		-M \\
		-R '@RG\\tID:${id}\\tSM:${id}\\tPL:illumina' \\
		-t ${task.cpus} \\
		$genome_file $r1 $r2 \\
		| sentieon util sort \\
		-r $genome_file \\
		-o ${id}_merged.bam \\
		-t ${task.cpus} --sam2bam -i -
	"""
}



// Collect information that will be used by to remove duplicate reads.
// The output of this step needs to be uncompressed (Sentieon manual uses .gz)
// or the command will occasionally crash in Sentieon 201808.07 (works in earlier)
process locus_collector {
	cpus 16

	input:
		set id, file(bam), file(bai), val(shard_name), val(shard) from bam.mix(merged_bam).combine(shards1)

	output:
		set val(id), file("${shard_name}_${id}.score"), file("${shard_name}_${id}.score.idx") into locus_collector_scores
		set val(id), file(bam), file(bai) into merged_bam_id

	"""
	sentieon driver \\
		-t ${task.cpus} \\
		-i $bam $shard \\
		--algo LocusCollector \\
		--fun score_info ${shard_name}_${id}.score
	"""
}



locus_collector_scores
    .groupTuple()
    .join(merged_bam_id)
    .combine(shards2)
    .set{ all_scores }


// Remove duplicate reads
process dedup {
	cpus 16
	cache 'deep'

	input:
		set val(id), file(score), file(idx), file(bam), file(bai), val(shard_name), val(shard) from all_scores

	output:
		set val(id), file("${shard_name}_${id}.bam"), file("${shard_name}_${id}.bam.bai") into shard_dedup_bam
		set val(group_id), file("${shard_name}_${id}.bam"), file("${shard_name}_${id}.bam.bai") into dnascope_bams
		set id, file("${shard_name}_${id}_dedup_metrics.txt") into dedup_metrics

	script:
		scores = score.sort(false) { a, b -> a.getBaseName().tokenize("_")[0] as Integer <=> b.getBaseName().tokenize("_")[0] as Integer } .join(' --score_info ')

	"""
	sentieon driver \\
		-t ${task.cpus} \\
		-i $bam $shard \\
		--algo Dedup --score_info $scores \\
		--metrics ${shard_name}_${id}_dedup_metrics.txt \\
		--rmdup ${shard_name}_${id}.bam
	"""

}

shard_dedup_bam
    .groupTuple()
    .into{ all_dedup_bams1; all_dedup_bams2; all_dedup_bams4 }

//merge shards with shard combinations
shards3
    .merge(tuple(shardie1))
    .into{ shard_shard; shard_shard2 }

process dedup_metrics_merge {

	input:
		set id, file(dedup) from dedup_metrics.groupTuple()

	output:
		set id, file("dedup_metrics.txt") into merged_dedup_metrics

	"""
	sentieon driver --passthru --algo Dedup --merge dedup_metrics.txt $dedup
	"""
}

//Collect various QC data: TODO MOVE qc_sentieon to container!
process sentieon_qc {
	cpus 54
	memory '64 GB'
	publishDir "${OUTDIR}/qc", mode: 'copy' , overwrite: 'true'

	input:
		set id, file(bam), file(bai), file(dedup) from qc_bam.mix(qc_merged_bam).join(merged_dedup_metrics)

	output:
		set id, file("${id}.QC") into qc_cdm

	"""
	sentieon driver \\
		-r $genome_file -t ${task.cpus} \\
		-i ${bam} \\
		--algo MeanQualityByCycle mq_metrics.txt \\
		--algo QualDistribution qd_metrics.txt \\
		--algo GCBias --summary gc_summary.txt gc_metrics.txt \\
		--algo AlignmentStat aln_metrics.txt \\
		--algo InsertSizeMetricAlgo is_metrics.txt \\
		--algo WgsMetricsAlgo wgs_metrics.txt
	qc_sentieon.pl $id wgs > ${id}.QC
	"""
}


// Load QC data into CDM (via middleman)
process qc_to_cdm {
	cpus 1
	publishDir "${CRONDIR}/qc", mode: 'copy' , overwrite: 'true'
	
	input:
		set id, file(qc) from qc_cdm
		set id, diagnosis, r1, r2 from qc_extra

	output:
		file("${id}.cdm") into cdm_done

	script:
		parts = r1.split('/')
		idx =  parts.findIndexOf {it ==~ /......_......_...._........../}
		rundir = parts[0..idx].join("/")

	"""
	echo "--run-folder $rundir --sample-id $id --subassay $diagnosis --assay tumwgs --qc ${OUTDIR}/qc/${id}.QC" > ${id}.cdm
	"""
}



process bqsr {
	cpus 16

	input:
		set val(id), file(bams), file(bai), val(shard_name), val(shard), val(one), val(two), val(three) from all_dedup_bams1.combine(shard_shard)

	output:
		set val(id), file("${shard_name}_${id}.bqsr.table") into bqsr_table

	script:
		combo = [one, two, three]
		combo = (combo - 0) //first dummy value
		combo = (combo - (genomic_num_shards+1)) //last dummy value
		commons = combo.collect{ "${it}_${id}.bam" }   //add .bam to each shardie, remove all other bams
		bam_neigh = commons.join(' -i ')

	"""
	sentieon driver \\
		-t ${task.cpus} \\
		-r $genome_file \\
		-i $bam_neigh $shard \\
		--algo QualCal -k $params.KNOWN1 -k $params.KNOWN2 ${shard_name}_${id}.bqsr.table
	"""
}

// Merge the bqrs shards
process merge_bqsr {
	input:
		set id, file(tables) from bqsr_table.groupTuple()

	output:
		set val(id), file("${id}_merged.bqsr.table") into bqsr_merged

	"""
	sentieon driver \\
		--passthru \\
		--algo QualCal \\
		--merge ${id}_merged.bqsr.table $tables
	"""
}

process merge_dedup_bam {
	cpus 1
	publishDir "${OUTDIR}/bam", mode: 'copy', overwrite: 'true'

	input:
		set val(id), file(bams), file(bais) from all_dedup_bams4

	output:
		set group, id, file("${id}_merged_dedup.bam"), file("${id}_merged_dedup.bam.bai") into chanjo_bam, cov_bam, freebayes_bam, vardict_bam

	script:
		bams_sorted_str = bams.sort(false) { a, b -> a.getBaseName().tokenize("_")[0] as Integer <=> b.getBaseName().tokenize("_")[0] as Integer } .join(' -i ')
		group = "bams"

	"""
	sentieon util merge -i ${bams_sorted_str} -o ${id}_merged_dedup.bam --mergemode 10
	"""
}


// Calculate coverage for chanjo
/*process chanjo_sambamba {
	cpus 16
	memory '64 GB'

	input:	
		set group, id, file(bam), file(bai) from chanjo_bam

	output:
		file("${id}_.bwa.chanjo.cov") into chanjocov

	"""
	sambamba depth region -t ${task.cpus} -L $scoutbed -T 10 -T 15 -T 20 -T 50 -T 100 $bam > ${id}_.bwa.chanjo.cov
	"""
}*/

bqsr_merged
    .groupTuple()
    .into{ bqsr_merged1; bqsr_merged2;}

all_dedup_bams2
    .join(bqsr_merged1)
    .set{ all_dedup_bams3 }


dnascope_bams.groupTuple().set { allbams }

all_dedup_bams3
    .combine(shard_shard2).groupTuple(by:5).combine(allbams)
    .set{ bam_shard_shard }

// Do variant calling using DNAscope, sharded
process dnascope {
	cpus 16

	input:
		set id, bams_dummy, bai_dummy, bqsr, val(shard_name), val(shard), val(one), val(two), val(three), val(grid), file(bams), file(bai) from bam_shard_shard

	output:
		set grid, file("${shard_name[0]}.vcf"), file("${shard_name[0]}.vcf.idx") into vcf_shard

	script:
		combo = [one[0], two[0], three[0]] // one two three take on values 0 1 2, 1 2 3...30 31 32
		combo = (combo - 0) //first dummy value removed (0)
		combo = (combo - (genomic_num_shards+1)) //last dummy value removed (32)
		commonsT = (combo.collect{ "${it}_${id[0]}.bam" })   //add .bam to each combo to match bam files from input channel
		commonsN = (combo.collect{ "${it}_${id[1]}.bam" })   //add .bam to each combo to match bam files from input channel
		bam_neighT = commonsT.join(' -i ') 
		bam_neighN = commonsN.join(' -i ') 

	"""
	/opt/sentieon-genomics-201711.05/bin/sentieon driver \\
		-t ${task.cpus} \\
		-r $genome_file \\
		-i $bam_neighT -i $bam_neighN $shard \\
		-q ${bqsr[0][0]} -q ${bqsr[1][0]} \\
		--algo TNscope --disable_detector sv --tumor_sample ${id[0]} --normal_sample ${id[1]}  ${shard_name[0]}.vcf
	"""
}


// Variant calling with freebayes
process freebayes {
    cpus 1

    input:
		set gr, id, file(bam), file(bai) from freebayes_bam.groupTuple(by:1).view()
		each file(bed) from beds_freebayes

	output:
		set val("freebayes"), gr, file("freebayes_${bed}.vcf") into vcfparts_freebayes

//	when:
//	    params.freebayes

	script:
		if( mode == "paired" ) {
			"""
			freebayes -f $genome_file -t $bed --pooled-continuous --pooled-discrete --min-repeat-entropy 1 -F 0.03 $bam > freebayes_${bed}.vcf.raw
			vcffilter -F LowCov -f "DP > 30" -f "QA > 150" freebayes_${bed}.vcf.raw | vcffilter -F LowFrq -o -f "AB > 0.05" -f "AB = 0" | vcfglxgt > freebayes_${bed}.filt1.vcf
			filter_freebayes_somatic.pl freebayes_${bed}.filt1.vcf > freebayes_${bed}.vcf
			"""
		}
		else if( mode == "unpaired" ) {
			"""
			freebayes -f $genome_file -t $bed --pooled-continuous --pooled-discrete --min-repeat-entropy 1 -F 0.03 $bam > freebayes_${bed}.vcf
			"""
		}
}
    
process vardict {
    cpus 1

    input:
		set gr, id, file(bam), file(bai) from vardict_bam.groupTuple(by:1).view()
		each file(bed) from beds_vardict

    output:
		set val("vardict"), gr, file("vardict_${bed}.vcf") into vcfparts_vardict

    when:
		params.vardict

    script:
	if( mode == "paired" ) {
		"""
		export JAVA_HOME=/opt/conda/envs/CMD-TUMWGS
		vardict-java -G $genome_file -f 0.03 -N ${gr}_T -b "$bam" -c 1 -S 2 -E 3 -g 4 $bed | testsomatic.R | var2vcf_paired.pl -N "${gr}_T|${gr}_N" -f 0.03 > vardict_${bed}.vcf
		"""
	}
	else if( mode == "unpaired" ) {
		"""
		export JAVA_HOME=/opt/conda/envs/CMD-TUMWGS
		vardict-java -G $genome_file -f 0.03 -N ${gr}_T -b $bamT -c 1 -S 2 -E 3 -g 4 $bed | teststrandbias.R | var2vcf_valid.pl -N ${gr}_T -E -f 0.03 > vardict_${bed}.vcf
		"""
	}
}

// Prepare vcf parts for concatenation
vcfparts_freebayes = vcfparts_freebayes.groupTuple(by:[0,1])
vcfparts_vardict   = vcfparts_vardict.groupTuple(by:[0,1])
vcfs_to_concat     = vcfparts_freebayes.mix(vcfparts_vardict).view()

process concatenate_vcfs {
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: true

	input:
		set vc, gr, file(vcfs) from vcfs_to_concat

	output:
		set val("sample"), file("${gr}_${vc}.vcf.gz") into concatenated_vcfs

	"""
	vcf-concat $vcfs | vcf-sort -c | gzip -c > ${vc}.concat.vcf.gz
	vt decompose ${vc}.concat.vcf.gz -o ${vc}.decomposed.vcf.gz
	vt normalize ${vc}.decomposed.vcf.gz -r $genome_file | vt uniq - -o ${gr}_${vc}.vcf.gz
	"""
}

    

// Merge vcf shards
process merge_vcf {
	cpus 16

	input:
		set id, file(vcfs), file(idx) from vcf_shard.groupTuple()
        
	output:
		set group, file("${id}.dnascope.vcf"), file("${id}.dnascope.vcf.idx") into complete_vcf

	script:
		group = "vcfs"
		vcfs_sorted = vcfs.sort(false) { a, b -> a.getBaseName().tokenize("_")[0] as Integer <=> b.getBaseName().tokenize("_")[0] as Integer } .join(' ')

	"""
	/opt/sentieon-genomics-201711.05/bin/sentieon driver \\
		-t ${task.cpus} \\
		--passthru \\
		--algo DNAscope \\
		--merge ${id}.dnascope.vcf $vcfs_sorted
	"""
}

complete_vcf
    .groupTuple()
    .set{ gvcfs }

process gvcf_combine {
	cpus 16

	input:
		set id, file(vcf), file(idx) from gvcfs
		set val(group), val(id), r1, r2 from vcf_info

	output:
		set group, file("${group}.combined.vcf"), file("${group}.combined.vcf.idx") into combined_vcf

	script:
		// Om fler än en vcf, GVCF combine annars döp om och skickade vidare
		if (mode == "family" ) {
			ggvcfs = vcf.join(' -v ')

			"""
			sentieon driver \\
				-t ${task.cpus} \\
				-r $genome_file \\
				--algo GVCFtyper \\
				-v $ggvcfs ${group}.combined.vcf
			"""
		}
		// annars ensam vcf, skicka vidare
		else {
			ggvcf = vcf.join('')
			gidx = idx.join('')

			"""
			mv ${ggvcf} ${group}.combined.vcf
			mv ${gidx} ${group}.combined.vcf.idx
			"""
		}
}

// Splitting & normalizing variants:
process split_normalize {
	cpus 1
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: 'true'

	input:
		set group, file(vcf), file(idx) from combined_vcf

	output:
		set group, file("${group}.norm.uniq.DPAF.vcf") into split_norm, vcf_gnomad

	"""
	vcfbreakmulti ${vcf} > ${group}.multibreak.vcf
	bcftools norm -m-both -c w -O v -f $genome_file -o ${group}.norm.vcf ${group}.multibreak.vcf
	vcfstreamsort ${group}.norm.vcf | vcfuniq > ${group}.norm.uniq.vcf
	wgs_DPAF_filter.pl ${group}.norm.uniq.vcf > ${group}.norm.uniq.DPAF.vcf
	"""

}

// Intersect VCF, exome/clinvar introns
process intersect {

	input:
		set group, file(vcf) from split_norm

	output:
		set group, file("${group}.intersected.vcf") into split_vep, split_cadd, vcf_loqus

	"""
	bedtools intersect -a $vcf -b $params.intersect_bed -u -header > ${group}.intersected.vcf
	"""

}

process annotate_vep {
	container = '/fs1/resources/containers/ensembl-vep_latest.sif'
	cpus 54

	input:
		set group, file(vcf) from split_vep

	output:
		set group, file("${group}.vep.vcf") into vep

	"""
	vep \\
		-i ${vcf} \\
		-o ${group}.vep.vcf \\
		--offline \\
		--everything \\
		--merged \\
		--vcf \\
		--no_stats \\
		--fork ${task.cpus} \\
		--force_overwrite \\
		--plugin CADD,$CADD \\
		--plugin LoFtool \\
		--plugin MaxEntScan,$MAXENTSCAN,SWA,NCSS \\
		--fasta $VEP_FASTA \\
		--dir_cache $VEP_CACHE \\
		--dir_plugins $VEP_CACHE/Plugins \\
		--distance 200 \\
		-cache \\
		-custom $GNOMAD \\
		-custom $GERP \\
		-custom $PHYLOP \\
		-custom $PHASTCONS
	"""
}

// Annotating variants with clinvar
process annotate_clinvar {
        cpus 1
        memory '32GB'

	input:
		set group, file(vcf) from vep

	output:
		set group, file("${group}.clinvar.vcf") into snpsift

	"""
	SnpSift -Xmx60g annotate $CLINVAR \\
		-info CLNSIG,CLNACC,CLNREVSTAT $vcf > ${group}.clinvar.vcf
	"""

}

// Extracting most severe consequence: 
// Modifying annotations by VEP-plugins, and adding to info-field: 
// Modifying CLNSIG field to allow it to be used by genmod score properly:
process modify_vcf {
	cpus 1

	input:
		set group, file(vcf) from snpsift

	output:
		set group, file("${group}.mod.vcf") into scored_vcf

	"""
	modify_vcf_scout.pl $vcf > ${group}.mod.vcf
	"""
} 


// Bgzipping and indexing VCF: 
process vcf_completion {
	cpus 16
	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: 'true'

	input:
		set group, file(vcf) from scored_vcf

	output:
		set group, file("${group}.tnscope.vcf.gz"), file("${group}.tnscope.vcf.gz.tbi") into vcf_done

	"""
	bgzip -@ ${task.cpus} $vcf -f
	tabix ${vcf}.gz -f
	mv ${vcf.gz} ${group}.tnscope.vcf.gz
	"""
}

vcf_done.into {
    vcf_done1
    vcf_done2
    vcf_done3
}



// Extract all variants (from whole genome) with a gnomAD af > x%
/*process fastgnomad {
	cpus 2
	memory '16 GB'

	publishDir "${OUTDIR}/vcf", mode: 'copy', overwrite: 'true'

    input:
		set group, file(vcf) from vcf_gnomad

	output:
		set group, file("${group}.SNPs.vcf") into vcf_upd, vcf_roh

	"""
	gzip -c $vcf > ${vcf}.gz
	annotate -g $params.FASTGNOMAD_REF -i ${vcf}.gz > ${group}.SNPs.vcf
	"""
	
}*/


// Create coverage profile using GATK
/*process gatkcov {
	publishDir "${OUTDIR}/cov", mode: 'copy' , overwrite: 'true'    
    
	cpus 2
	memory '16 GB'

	input:
		set group, id, file(bam), file(bai) from cov_bam
		set gr, id, sex, mother, father, phenotype, diagnosis from meta_gatkcov

	output:
		set file("${id}.standardizedCR.tsv"), file("${id}.denoisedCR.tsv") into cov_plot

	"""
	source activate gatk4-env

	gatk CollectReadCounts \
		-I $bam -L $params.COV_INTERVAL_LIST \
		--interval-merging-rule OVERLAPPING_ONLY -O ${bam}.hdf5

	gatk --java-options "-Xmx12g" DenoiseReadCounts \
		-I ${bam}.hdf5 --count-panel-of-normals ${PON[sex]} \
		--standardized-copy-ratios ${id}.standardizedCR.tsv \
		--denoised-copy-ratios ${id}.denoisedCR.tsv

	gatk PlotDenoisedCopyRatios \
		--standardized-copy-ratios ${id}.standardizedCR.tsv \
		--denoised-copy-ratios ${id}.denoisedCR.tsv \
		--sequence-dictionary $params.GENOMEDICT \
		--minimum-contig-length 46709983 --output . --output-prefix $id
	"""
}*/


