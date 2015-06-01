

# some basic definitions for generic matches

execute(k::Config, m, s, i) = error("$m did not expect to be called with state $s")

response(k::Config, m, s, t, i, r) = error("$m did not expect to receive state $s, response $r")

execute(k::Config, m::Matcher, s::Dirty, i) = Response(s, i, FAILURE)



# many matchers delegate to a child, making only slight modifications.
# we can describe the default behaviour just once, here.
# child matchers then need to implement (1) state creation (typically on 
# response) and (2) anything unusual (ie what the matcher actually does)

# assume this has a matcher field
abstract Delegate<:Matcher

# assume this has a state field
abstract DelegateState<:State

execute(k::Config, m::Delegate, s::Clean, i) = Execute(m, s, m.matcher, CLEAN, i)

execute(k::Config, m::Delegate, s::DelegateState, i) = Execute(m, s, m.matcher, s.state, i)

# this avoids re-calling child on backtracking on failure
response(k::Config, m::Delegate, s, t, i, r::Failure) = Response(DIRTY, i, FAILURE)



# various weird things for completeness

immutable Epsilon<:Matcher end

execute(k::Config, m::Epsilon, s::Clean, i) = Response(DIRTY, i, EMPTY)

immutable Insert<:Matcher
    text
end

execute(k::Config, m::Insert, s::Clean, i) = Response(DIRTY, i, Success(m.text))

immutable Dot<:Matcher end

function execute(k::Config, m::Dot, s::Clean, i)
    if done(k.source, i)
        Response(DIRTY, i, FAILURE)
    else
        c, i = next(k.source, i)
        Response(DIRTY, i, Success(c))
    end
end



# evaluate the sub-matcher, but replace the result with EMPTY

immutable Drop<:Delegate
    matcher::Matcher
end

immutable DropState<:DelegateState
    state::State
end

response(k::Config, m::Drop, s, t, i, rs::Success) = Response(DropState(t), i, EMPTY)



# exact match

immutable Equal<:Matcher
    string
end

function execute(k::Config, m::Equal, s::Clean, i)
    for x in m.string
        if done(k.source, i)
            return Response(DIRTY, i, FAILURE)
        end
        y, i = next(k.source, i)
        if x != y
            return Response(DIRTY, i, FAILURE)
        end
    end
    Response(DIRTY, i, Success(m.string))
end



# repetition (greedy and minimal)
# Repeat(m, hi, lo) is greedy; Repeat(m, lo, hi) is lazy

immutable Repeat<:Matcher
    matcher::Matcher
    a::Integer
    b::Integer
end

ALL = typemax(Int)

abstract RepeatState<:State

abstract Greedy<:RepeatState

immutable Slurp<:Greedy
    # there's a mismatch in lengths here because the empty results is
    # associated with an iter and state
    results::Array{Value,1}  # accumulated during slurp
    iters::Array{Any,1}      # at the end of the associated result
    states::Array{State,1}     # at the end of the associated result
end

immutable Yield<:Greedy
    results::Array{Value,1}
    iters::Array{Any,1}
    states::Array{State,1}
end

immutable Backtrack<:Greedy
    results::Array{Value,1}
    iters::Array{Any,1}
    states::Array{State,1}
end

immutable Lazy<:RepeatState
end

# when first called, create base state and make internal transition

function execute(k::Config, m::Repeat, s::Clean, i)
    if m.b > m.a
        error("lazy repeat not yet supported")
        execute(k, m, Lazy(), i)
    else
        execute(k, m, Slurp(Array(Value, 0), [i], Any[s]), i)
    end
end

# match until complete

work_to_do(m::Repeat, results) = m.a > length(results)

function execute(k::Config, m::Repeat, s::Slurp, i)
    if work_to_do(m, s.results)
        Execute(m, s, m.matcher, CLEAN, i)
    else
        execute(k, m, Yield(s.results, s.iters, s.states), i)
    end
end

function response(k::Config, m::Repeat, s::Slurp, t, i, r::Success)
    results = Value[s.results..., r.value]
    iters = vcat(s.iters, i)
    states = vcat(s.states, t)
    if work_to_do(m, results)
        Execute(m, Slurp(results, iters, states), m.matcher, CLEAN, i)
    else
        execute(k, m, Yield(results, iters, states), i)
    end
end

function response(k::Config, m::Repeat, s::Slurp, t, i, ::Failure)
    execute(k, m, Yield(s.results, s.iters, s.states), i)
end

# yield a result

function execute(k::Config, m::Repeat, s::Yield, i)
    n = length(s.results)
    if n >= m.b
        Response(Backtrack(s.results, s.iters, s.states), s.iters[end], Success(flatten(s.results)))
    else
        Response(DIRTY, i, FAILURE)
    end
end

# another result is required, so discard and then advance if possible

function execute(k::Config, m::Repeat, s::Backtrack, i)
    if length(s.iters) < 2  # is this correct?
        Response(DIRTY, i, FAILURE)
    else
        # we need the iter from *before* the result
        Execute(m, Backtrack(s.results[1:end-1], s.iters[1:end-1], s.states[1:end-1]), m.matcher, s.states[end], s.iters[end-1])
    end
end

function response(k::Config, m::Repeat, s::Backtrack, t, i, r::Success)
    execute(k, m, Slurp(Array{Value}[s.results... r.value], vcat(s.iters, i), vcat(s.states, t)), i)
end

function response(k::Config, m::Repeat, s::Backtrack, t, i, ::Failure)
    execute(k, m, Yield(s.results, s.iters, s.states), i)
end

# see sugar.jl for [] syntax support

Star(m::Matcher) = m[0:end]
Plus(m::Matcher) = m[1:end]



# match all in a sequence with backtracking
# there are two nearly identical matchers here - the only difference is 
# whether results are merged (Seq/+) or Not(And/&).

abstract Serial<:Matcher

immutable Seq<:Serial
    matchers::Array{Matcher,1}
    Seq(matchers::Matcher...) = new([matchers...])
    Seq(matchers::Array{Matcher,1}) = new(matchers)    
end

serial_success(m::Seq, results) = Success(flatten(results))

immutable And<:Serial
    matchers::Array{Matcher,1}
    And(matchers::Matcher...) = new([matchers...])
    And(matchers::Array{Matcher,1}) = new(matchers)    
end

# copy tso that state remains immutable
serial_success(m::And, results) = Success([results;])

immutable SerialState<:State
    results::Array{Value,1}
    iters::Array{Any,1}
    states::Array{State,1}
end

# when first called, call first matcher

function execute(l::Config, m::Serial, s::Clean, i) 
    if length(m.matchers) == 0
        Response(DIRTY, i, EMPTY)
    else
        Execute(m, SerialState(Value[], [i], State[]), m.matchers[1], CLEAN, i)
    end
end

# if the final matcher matched then return what we have.  otherwise, evaluate
# the next.

function response(k::Config, m::Serial, s::SerialState, t, i, r::Success)
    n = length(s.iters)
    results = Value[s.results..., r.value]
    iters = vcat(s.iters, i)
    states = vcat(s.states, t)
    if n == length(m.matchers)
        Response(SerialState(results, iters, states), i, serial_success(m, results))
    else
        Execute(m, SerialState(results, iters, states), m.matchers[n+1], CLEAN, i)
    end
end

# if the first matcher failed, fail.  otherwise backtrack

function response(k::Config, m::Serial, s::SerialState, t, i, r::Failure)
    n = length(s.iters)
    if n == 1
        Response(DIRTY, s.iters[1], FAILURE)
    else
        Execute(m, SerialState(s.results[1:end-1], s.iters[1:end-1], s.states[1:end-1]), m.matchers[n-1], s.states[end], s.iters[end-1])
    end
end

# try to advance the current match

function execute(k::Config, m::Serial, s::SerialState, i)
    @assert length(s.states) == length(m.matchers)
    Execute(m, SerialState(s.results[1:end-1], s.iters[1:end-1], s.states[1:end-1]), m.matchers[end], s.states[end], s.iters[end-1])
end




# backtracked alternates

immutable Alt<:Matcher
    matchers::Array{Matcher,1}
    Alt(matchers::Matcher...) = new([matchers...])
    Alt(matchers::Array{Matcher,1}) = new(matchers)    
end

immutable AltState<:State
    state::State
    iter
    i
end

function execute(k::Config, m::Alt, s::Clean, i)
    if length(m.matchers) == 0
        Response(DIRTY, i, FAILURE)
    else
        execute(k, m, AltState(CLEAN, i, 1), i)
    end
end

function execute(k::Config, m::Alt, s::AltState, i)
    Execute(m, s, m.matchers[s.i], s.state, s.iter)
end

function response(k::Config, m::Alt, s::AltState, t, i, r::Success)
    Response(AltState(t, s.iter, s.i), i, r)
end

function response(k::Config, m::Alt, s::AltState, t, i, r::Failure)
    if s.i == length(m.matchers)
        Response(DIRTY, i, FAILURE)
    else
        execute(k, m, AltState(CLEAN, s.iter, s.i + 1), i)
    end
end



# evaluate the child, but discard values and do not advance the iter

immutable Lookahead<:Delegate
    matcher::Matcher
end

immutable LookaheadState<:DelegateState
    state::State
    iter
end

execute(k::Config, m::Lookahead, s::Clean, i) = Execute(m, LookaheadState(s, i), m.matcher, CLEAN, i)

response(m::Lookahead, s, t, i, r::Success) = Response(LooakheadState(t, s.iter), s.iter, EMPTY)



# if the child matches, fail; if the child fails return EMPTY
# no backtracking of the child is supported (i don't understand how it would
# work, but feel free to correct me....)

immutable Not<:Matcher
    matcher::Matcher
end

immutable NotState<:State
    iter
end

execute(k::Config, m::Not, s::Clean, i) = Execute(m, NotState(i), m.matcher, CLEAN, i)

response(k::Config, m::Not, s, t, i, r::Success) = Response(s, s.iter, FAILURE)

response(k::Config, m::Not, s, t, i, r::Failure) = Response(s, s.iter, EMPTY)


# match a regular expression.

# because Regex match against strings, this matcher works only against 
# string sources.

# for efficiency, we need to know the offset where the match finishes.
# we do this by adding r"(.??)" to the end of the expression and using
# the offset from that.

# we also prepend ^ to anchor the match

immutable Pattern<:Matcher
    regex::Regex
    Pattern(r::Regex) = new(Regex("^" * r.pattern * "(.??)"))
    Pattern(s::AbstractString) = new(Regex("^" * s * "(.??)"))
end

function execute(k::Config, m::Pattern, s::Clean, i)
    @assert isa(k.source, AbstractString)
    x = match(m.regex, k.source[i:end])
    if x == nothing
        Response(DIRTY, i, FAILURE)
    else
        Response(DIRTY, i + x.offsets[end] - 1, Success(x.match))
    end
end



# support loops

type Delayed<:Matcher
    matcher::Nullable{Matcher}
    Delayed() = new(Nullable{Matcher}())
end

function execute(k::Config, m::Delayed, s::Dirty, i)
    Response(DIRTY, i, FAILURE)
end

function execute(k::Config, m::Delayed, s::State, i)
    if isnull(m.matcher)
        error("assign to the Delayed() matcher attribute")
    else
        execute(k, get(m.matcher), s, i)
    end
end



# enable debug when in scope of child

immutable Debug<:Delegate
    matcher::Matcher
end

immutable DebugState<:DelegateState
    state::State
    depth::Int
end

execute(k::Config, m::Debug, s::Clean, i) = execute(k, m, DebugState(CLEAN, 0), i)

function execute(k::Config, m::Debug, s::DebugState, i)
    k.debug = true
    Execute(m, DebugState(s.state, s.depth+1), m.matcher, s.state, i)
end

function response(k::Config, m::Debug, s::DebugState, t, i, r::Success)
    if s.depth == 1
        k.debug = false
    end
    Response(DebugState(t, s.depth-1), i, r)
end
    
function response(k::Config, m::Debug, s::DebugState, t, i, r::Failure)
    if s.depth == 2
        k.debug = false
    end
    Response(DIRTY, i, FAILURE)
end
    


# end of stream / string

immutable Eos<:Matcher end

function execute(k::Config, m::Eos, s::Clean, i)
    if done(k.source, i)
        Response(DIRTY, i, EMPTY)
    else
        Response(DIRTY, i, FAILURE)
    end
end


