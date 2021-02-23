module Blocks

using Rematch, FStrings

import Base:
    show, length, append!, keys

# internal modules
using ..Intervals
using ..Nodes
using ..Utility: 
    random_id, contiguous_trues,
    uncigar, wcpair, partition, Alignment

import ..Graphs:
    pair, reverse_complement

# exports
export SNPMap, InsMap, DelMap   # aux types
export Block 
export sequence, sequence!, combine, swap! # operators

Maybe{T} = Union{T,Nothing}

# ------------------------------------------------------------------------
# Block data structure

# aliases
SNPMap = Dict{Int,UInt8}
InsMap = Dict{Tuple{Int,Int},Array{UInt8}} 
DelMap = Dict{Int,Int} 

show(io::IO, m::InsMap) = show(io, Dict(k => String(copy(v)) for (k,v) in m))

mutable struct Block
    uuid::String
    sequence::Array{UInt8}
    gaps::Dict{Int,Int}
    mutate::Dict{Node{Block},SNPMap}
    insert::Dict{Node{Block},InsMap}
    delete::Dict{Node{Block},DelMap}
end

# ---------------------------
# constructors

# simple helpers
Block(sequence,gaps,mutate,insert,delete) = Block(random_id(),sequence,gaps,mutate,insert,delete)
Block(sequence) = Block(sequence,Dict{Int,Int}(),Dict{Node{Block},SNPMap}(),Dict{Node{Block},InsMap}(),Dict{Node{Block},DelMap}())
Block()         = Block(UInt8[])

translate(dict, δ) = Dict(key=>Dict(x+δ => v for (x,v) in val) for (key,val) in dict)
function translate!(dict, δ)
    for (key, val) in dict
        dict[key] = Dict(x+δ => v for (x,v) in val)
    end
end

# TODO: rename to concatenate?
# serial concatenate list of blocks
function Block(bs::Block...)
    @assert all([isolates(bs[1]) == isolates(b) for b in bs[2:end]])

    sequence = join([b.sequence for b in bs])

    gaps   = bs[1].gaps
    mutate = bs[1].mutate
    insert = bs[1].insert
    delete = bs[1].delete

    δ = length(bs[1])
    for b in bs[2:end]
        merge!(gaps,   translate(b.gaps,   δ))
        merge!(mutate, translate(b.mutate, δ))
        merge!(insert, translate(b.insert, δ))
        merge!(delete, translate(b.delete, δ))

        δ += length(b)
    end

    return Block(sequence,gaps,mutate,insert,delete)
end

# TODO: rename to slice?
# returns a subslice of block b
function Block(b::Block, slice)
    @assert slice.start >= 1 && slice.stop <= length(b)
    sequence = b.sequence[slice]

    select(dict,i) = translate(
                        Dict(node => filter(p -> (first(p) >= i.start) && (first(p) <= i.stop), val) for (node,val) in dict), 
                     -i.start)

    gaps   = select(b.gaps,   slice)
    mutate = select(b.mutate, slice)
    insert = select(b.insert, slice)
    delete = select(b.delete, slice)

    return Block(sequence,gaps,mutate,insert,delete)
end

# ---------------------------
# operations

# simple operations
depth(b::Block) = length(b.mutate)
pair(b::Block)  = b.uuid => b

show(io::IO, b::Block) = show(io, (id=b.uuid, depth=depth(b)))

length(b::Block) = length(b.sequence)
length(b::Block, n::Node) = (length(b)
                          +((length(b.insert[n]) == 0) ? 0 : sum(length(i) for i in values(b.insert[n])))
                          -((length(b.delete[n]) == 0) ? 0 : sum(values(b.delete[n]))))

keys(b::Block) = keys(b.mutate)

# internal structure to allow us to sort all allelic types
Locus = Union{
    NamedTuple{(:pos, :kind), Tuple{Int, Symbol}},
    NamedTuple{(:pos, :kind), Tuple{Tuple{Int,Int}, Symbol}},
}

islesser(a::Int, b::Int)                       = isless(a, b)
islesser(a::Tuple{Int,Int}, b::Int)            = isless(first(a), b)
islesser(a::Int, b::Tuple{Int,Int})            = isless(a, first(b)) || a == first(b)
islesser(a::Tuple{Int,Int}, b::Tuple{Int,Int}) = isless(a, b)

islesser(a::Locus, b::Locus) = islesser(a.pos, b.pos)

function allele_positions(b::Block, n::Node)
    keys(dict, sym) = [(pos=key, kind=sym) for key in Base.keys(dict)]
    return [keys(b.mutate[n],:snp); keys(b.insert[n],:ins); keys(b.delete[n],:del)]
end

# complex operations
function reverse_complement(b::Block)
    seq = reverse_complement(b.sequence)
    len = length(seq)

    revcmpl(dict::SNPMap) = Dict(len-locus+1:wcpair[nuc]  for (locus,nuc) in dict)
    revcmpl(dict::DelMap) = Dict(len-locus+1:del for (locus,del) in dict)
    revcmpl(dict::InsMap) = Dict((len-locus+1,b.gaps[locus]-off+1):reverse_complement(ins) for ((locus,off),ins) in dict)

    mutate = Dict(node => revcmpl(snp) for (node, snp) in b.mutate)
    insert = Dict(node => revcmpl(ins) for (node, ins) in b.insert)
    delete = Dict(node => revcmpl(del) for (node, del) in b.delete)
    gaps   = Dict(node => revcmpl(gap) for (node, gap) in b.gaps)

    return Block(seq,gaps,mutate,insert,delete)
end

function sequence(b::Block; gaps=false)
    !gaps && return b.sequence
    
    len = length(b) + sum(values(b.gaps))
    seq = Array{UInt8}(undef, len)

    l, iₛ = 1, 1
    for r in sort(collect(keys(b.gaps)))
        len = r - l
        seq[iₛ:iₛ+len] = b.sequence[l:r]

        iₛ += len + 1
        len = b.gaps[r]
        seq[iₛ:iₛ+len-1] .= UInt8('-')

        l   = r + 1
        iₛ += len
    end

    seq[iₛ:end] = b.sequence[l:end]

    return seq
end

function sequence_gaps!(seq, b::Block, node::Node{Block})
    ref = sequence(b; gaps=true)
    @assert length(seq) == length(ref)

    loci = allele_positions(b, node) 
    sort!(loci, lt=islesser)

    Ξ(x) = x + reduce(+,(δ for (l,δ) in b.gaps if l < x); init=0)

    for l in loci
        @match l.kind begin
            :snp => begin
                x      = l.pos
                seq[Ξ(x)] = b.mutate[node][x]
            end
            :ins => begin
                ins = b.insert[node][l.pos]
                len = length(ins)

                x = Ξ(l.pos[1]) # NOTE: insertion occurs AFTER the key position
                δ = l.pos[2]

                seq[x+δ+1:x+len+δ] = ins
            end
            :del => begin
                len = b.delete[node][l.pos]
                x   = Ξ(l.pos )

                seq[x:x+len-1] .= UInt8('-')
            end
              _  => error("unrecognized locus kind")
        end
    end

    return seq
end

function sequence_gaps(b::Block, node::Node{Block})
    len = length(b) + sum(values(b.gaps)) # TODO: make alignment_length function?
    seq = Array{UInt8}(undef, len)

    sequence_gaps!(seq, b, node)

    return seq
end

# returns the sequence WITH mutations and indels applied to the consensus for a given tag 
function sequence!(seq, b::Block, node::Node{Block}; gaps=false)
    gaps && return sequence_gaps!(seq, b, node)

    @assert length(seq) == length(b, node)

    ref = sequence(b; gaps=false)

    pos  = (l) -> isa(l.pos, Tuple) ? l.pos[1] : l.pos # dispatch over different key types
    loci = allele_positions(b, node)
    sort!(loci, lt=islesser)

    iᵣ, iₛ = 1, 1
    for l in loci
        if (δ = pos(l) - iᵣ) >= 0
            seq[iₛ:iₛ+δ-1] = ref[iᵣ:pos(l)-1]
            iₛ += δ
        end

        @match l.kind begin
            :snp => begin
                seq[iₛ] = b.mutate[node][l.pos]
                iₛ += 1
                iᵣ += δ + 1
            end
            :ins => begin
                # NOTE: insertions are indexed by the position they follow.
                #       since we stop 1 short, we finish here before continuing insertion.
                if δ >= 0
                    seq[iₛ] = ref[pos(l)]
                    iₛ += 1
                end

                ins = b.insert[node][l.pos]
                len = length(ins)

                seq[iₛ:iₛ+len-1] = ins

                iₛ += len
                iᵣ  = pos(l) + 1
            end
            :del => begin
                # NOTE: deletions index the first position of the deletion. 
                #       this is the reason we stop 1 short above
                iᵣ = l.pos + b.delete[node][l.pos]
            end
              _  => error("unrecognized locus kind")
        end
    end

    seq[iₛ:end] = ref[iᵣ:end]

    return seq
end

function sequence(b::Block, node::Node{Block}; gaps=false)
    seq = gaps ? sequence(b; gaps=true) : Array{UInt8}('-'^length(b, node))
    sequence!(seq, b, node; gaps=gaps)
    return seq
end

function append!(b::Block, node::Node{Block}, snp::Maybe{SNPMap}, ins::Maybe{InsMap}, del::Maybe{DelMap})
    @assert node ∉ keys(b.mutate)
    @assert node ∉ keys(b.insert)
    @assert node ∉ keys(b.delete)

    if isnothing(snp)
        snp = SNPMap()
    end

    if isnothing(ins)
        ins = InsMap()
    end

    if isnothing(del)
        del = DelMap()
    end

    b.mutate[node] = snp
    b.insert[node] = ins
    b.delete[node] = del
end

function swap!(b::Block, oldkey::Node{Block}, newkey::Node{Block})
    b.mutate[newkey] = pop!(b.mutate, oldkey)
    b.insert[newkey] = pop!(b.insert, oldkey)
    b.delete[newkey] = pop!(b.delete, oldkey)
end

function swap!(b::Block, oldkey::Array{Node{Block}}, newkey::Node{Block})
    mutate = pop!(b.mutate, oldkey[1])
    insert = pop!(b.insert, oldkey[1])
    delete = pop!(b.delete, oldkey[1])

    for key in oldkey[2:end]
        merge!(mutate, pop!(b.mutate, key))
        merge!(insert, pop!(b.insert, key))
        merge!(delete, pop!(b.delete, key))
    end

    b.mutate[newkey] = mutate
    b.insert[newkey] = insert
    b.delete[newkey] = delete 
end

function reconsensus!(b::Block)
    depth(b) <= 2 && return false # no point to compute this for blocks with 1 or 2 individuals

    ref = sequence(b; gaps=true)
    aln = Array{UInt8}(undef, length(ref), depth(b))
    for (i,node) in enumerate(keys(b))
        aln[:,i] = ref
        sequence!(view(aln,:,i), b, node; gaps=true)
    end

    consensus = [mode(view(aln,i,:)) for i in 1:size(aln,1)]

    for i in 1:depth(b)
        @show String(copy(aln[:,i]))
    end
    @show String(copy(consensus))

    isdiff = (aln .!= consensus)
    refdel = (consensus .== UInt8('-'))
    alndel = (aln .== UInt8('-'))

    δ = (
        snp = isdiff .& .!refdel .& .!alndel,
        del = isdiff .& .!refdel .&   alndel,
        ins = isdiff .&   refdel .& .!alndel,
    )

    coord = cumsum(.!refdel)

    # XXX: we assume that keys(b) will return the same order on subsequent calls
    #      this is fine as long as we don't modify the dictionary in between

    refgaps = contiguous_trues(refdel)

    @show b.gaps
    b.gaps  = Dict{Int, Int}(coord[gap.lo] => length(gap) for gap in refgaps)
    @show b.gaps
    
    @show b.mutate
    b.mutate = Dict{Node{Block},SNPMap}( 
            node => SNPMap(
                      coord[l] => aln[l,i] 
                for l in findall(δ.snp[:,i])
            )
        for (i,node) in enumerate(keys(b))
    )
    @show b.mutate

    @show b.delete
    b.delete = Dict{Node{Block},DelMap}( 
            node => DelMap(
                      coord[del.lo] => length(del)
                for del in contiguous_trues(δ.del[:,i])
             )
        for (i,node) in enumerate(keys(b))
    )
    @show b.delete

    @show b.insert
    Δ(I) = (R = containing(refgaps, I)) == nothing ? 0 : I.lo - R.lo
    b.insert = Dict{Node{Block},InsMap}( 
            node => InsMap(
                      (coord[ins.lo],Δ(ins)) => aln[ins,i] 
                for ins in contiguous_trues(δ.ins[:,i])
             )
        for (i,node) in enumerate(keys(b))
    )
    @show b.insert

    return true
end

function combine(qry::Block, ref::Block, aln::Alignment; maxgap=500)
    # NOTE: this will enforce that indels are less than maxgap!
    # TODO: rename partition function
    sequences,intervals,mutations,inserts,deletes = partition(
                                                         uncigar(aln.cigar),
                                                         qry.sequence,
                                                         ref.sequence,
                                                         maxgap=maxgap
                                                    )

    blocks = NamedTuple{(:block,:kind),Tuple{Block,Symbol}}[]

    for (seq,pos,snp,ins,del) in zip(sequences,intervals,mutations,inserts,deletes)
        @match (pos.qry, pos.ref) begin
            ( nothing, rₓ )  => push!(blocks, (block=Block(ref, rₓ), kind=:ref))
            ( qₓ , nothing ) => push!(blocks, (block=Block(qry, qₓ), kind=:qry))
            ( qₓ , rₓ )      => begin
                @assert !isnothing(snp)
                @assert !isnothing(ins)
                @assert !isnothing(del)

                # slice both blocks
                r = Block(ref, rₓ)
                q = Block(qry, qₓ)

                # apply global snp and indels to all query sequences
                # XXX: do we have to worry about overlapping insertions/deletions?
                for node in keys(q.mutate)
                    merge!(q.mutate[node],snp)
                    merge!(q.insert[node],ins)
                    merge!(q.delete[node],del)
                end

                gap = Dict(first(key)=>length(val) for (key,val) in ins)
                new = Block(seq,gap,snp,ins,del)

                reconsensus!(new)

                push!(blocks, (block=new, kind=:all))
            end
        end
    end

    return blocks
end

# ------------------------------------------------------------------------
# main point of entry for testing

using Random, Distributions, StatsBase

function generate_alignment(;len=100,num=10,μ=(snp=1e-2,ins=1e-2,del=1e-2),Δ=5)
    ref = Array{UInt8}(random_id(;len=len, alphabet=['A','C','G','T']))
    aln = zeros(UInt8, num, len)

    map = (
        snp = Array{SNPMap}(undef,num),
        ins = Array{InsMap}(undef,num),
        del = Array{DelMap}(undef,num),
    )
    ρ = (
        snp = Poisson(μ.snp*len),
        ins = Poisson(μ.ins*len),
        del = Poisson(μ.del*len),
    )
    n = (
        snp = rand(ρ.snp, num),
        ins = rand(ρ.ins, num),
        del = rand(ρ.del, num),
    )

    for i in 1:num
        aln[i,:] = ref
    end

    # random insertions
    # NOTE: this is the inverse operation as a deletion.
    #       perform operation as a collective.
    inserts = Array{IntervalSet{Int}}(undef, num)

    # first collect all insertion intervals
    for i in 1:num
        inserts[i] = IntervalSet(1, len+1)

        for j in 1:n.ins[i]
            @label getinterval
            start = sample(1:len)
            delta = len-start+1
            stop  = start + min(delta, sample(1:Δ))

            insert = Interval(start, stop)

            if !isdisjoint(inserts[i], insert)
                @goto getinterval # XXX: potential infinite loop
            end

            inserts[i] = inserts[i] ∪ insert
        end
    end

    allinserts = reduce(∪, inserts)

    δ = 1 
    gaps = [begin 
        x  = (I.lo-δ, length(I)) 
        δ += length(I)
        x
    end for I in allinserts]

    for (i, insert) in enumerate(inserts)
        keys = Array{Tuple{Int,Int}}(undef, length(insert))
        vals = Array{Array{UInt8}}(undef, length(insert))
        for (n, a) in enumerate(insert)
            for (j, b) in enumerate(allinserts)
                if a ⊆ b
                    keys[n] = (gaps[j][1], a.lo - b.lo)
                    vals[n] = ref[a]
                    @goto outer
                end
            end
            error("failed to find containing interval!")
            @label outer
        end

        map.ins[i] = InsMap(zip(keys,vals))

        # delete non-overlapping regions
        for j in allinserts \ insert
            aln[i,j] .= UInt8('-')
        end
    end

    idx = collect(1:len)[~allinserts]
    ref = ref[~allinserts]

    for i in 1:num
        index = collect(1:length(idx))
        deleteat!(index, findall(aln[i,idx] .== UInt8('-')))

        # random deletions
        # NOTE: care must be taken to ensure that they don't overlap or merge
        loci = Array{Int}(undef, n.del[i])
        dels = Array{Int}(undef, n.del[i])

        for j in 1:n.del[i]
            @label tryagain
            loci[j] = sample(index)

            while aln[i,max(1, idx[loci[j]]-1)] == UInt8('-')
                loci[j] = sample(index)
            end

            x = idx[loci[j]]

            offset = findfirst(aln[i,x:end] .== UInt8('-'))
            maxgap = isnothing(offset) ? (len-x+1) : (offset-1)

            dels[j] = min(maxgap, sample(1:Δ))

            # XXX: this is a hack to ensure deletions and insertions don't overlap
            if !all(item ∈ idx for item in x:x+dels[j]-1)
                @goto tryagain
            end

            aln[i,x:(x+dels[j]-1)] .= UInt8('-')
            filter!(i->i ∉ loci[j]:(loci[j]+dels[j]-1), index)
        end

        map.del[i] = DelMap(zip(loci,dels))
        
        # random single nucleotide polymorphisms
        # NOTE: we exclude the deleted regions
        loci = sample(index, n.snp[i]; replace=false)
        snps = sample(UInt8['A','C','G','T'], n.snp[i])
        redo = findall(ref[loci] .== snps)

        while length(redo) >= 1
            snps[redo] = sample(UInt8['A','C','G','T'], length(redo))
            redo = findall(ref[loci] .== snps)
        end

        for (locus,snp) in zip(loci,snps)
            aln[i,idx[locus]] = snp
        end

        map.snp[i] = SNPMap(zip(loci,snps))
    end

    return ref, aln, Dict(gaps), map
end

function verify(blk, node, aln, map)
    local pos = join([f"{i:02d}" for i in 1:10:101], ' '^8)
    local tic = join([f"|" for i in 1:10:101], '.'^9)

    local to_char(d::Dict{Int,UInt8}) = Dict{Int,Char}(k=>Char(v) for (k,v) in d)

    # for i in 1:size(aln,1)
    #     @show i, String(copy(aln[i,:]))
    # end
    ok = true
    for i in 1:size(aln,1)
        seq  = sequence(blk,node[i];gaps=true)
        good = size(aln,2) == length(seq) && aln[i,:] .== seq
        if !all(good)
            ok = false

            err        = copy(seq)
            err[good] .= ' '

            println(f"failure on row {i}")
            println("Loci: ", pos)
            println("      ", tic)
            println("True: ", String(copy(aln[i,:])))
            println("Estd: ", String(copy(seq)))
            println("Diff: ", String(err))
            println("SNPs: ", to_char(map.snp[i]))
            println("Dels: ", map.del[i])
            println("Ints: ", map.ins[i])
            break
        end
        seq  = sequence(blk,node[i];gaps=false)
    end

    return ok
end

function test()
    ref, aln, gap, map = generate_alignment()

    blk = Block(ref)
    blk.gaps = gap

    node = [Node{Block}(blk,true) for i in 1:size(aln,1)]
    for i in 1:size(aln,1)
        append!(blk, node[i], map.snp[i], map.ins[i], map.del[i])
    end

    ok = verify(blk, node, aln, map)
    if !ok
        error("failure to initialize block correctly")
    end

    reconsensus!(blk)

    ok = verify(blk, node, aln, map)
    if !ok
        error("failure to reconsensus block correctly")
    end

    return ok 
end

end
