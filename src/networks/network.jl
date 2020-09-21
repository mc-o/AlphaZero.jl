"""
A generic, framework agnostic interface for neural networks.
"""
module Network

export AbstractNetwork, OptimiserSpec, CyclicNesterov, Adam

import ..MCTS, ..GI, ..Util

using Base: @kwdef
using Statistics: mean

"""
    AbstractNetwork <: MCTS.Oracle

Abstract base type for a neural network.

# Constructor

Any subtype `Network` must implement `Base.copy` along with
the following constructor:

    Network(hyperparams, input_size, output_size)

where the expected type of `hyperparams` is given by
[`HyperParams(Network)`](@ref HyperParams).
"""
abstract type AbstractNetwork <: MCTS.Oracle end

#####
##### Interface
#####

"""
    HyperParams(::Type{<:AbstractNetwork})

Return the hyperparameter type associated with a given network type.
"""
function HyperParams end

"""
    hyperparams(::AbstractNetwork)

Return the hyperparameters of a network.
"""
function hyperparams end

"""
    to_gpu(::AbstractNetwork)

Return a copy of the given network that has been transferred to the GPU
if one is available. Otherwise, return the given network untouched.
"""
function to_gpu end

"""
    to_cpu(::AbstractNetwork)

Return a copy of the given network that has been transferred to the CPU
or return the given network untouched if it is already on CPU.
"""
function to_cpu end

"""
    on_gpu(::AbstractNetwork) :: Bool

Test whether or not a network is located on GPU.
"""
function on_gpu end

"""
    set_test_mode!(mode=true)

Put a network in test mode or in training mode.
This is relevant for networks featuring layers such as
batch normalization layers.
"""
function set_test_mode! end

"""
    convert_input(::AbstractNetwork, input)

Convert an array (or number) to the right format so that it can be used
as an input by a given network.
"""
function convert_input end

function convert_input_tuple(nn::AbstractNetwork, input::Tuple)
  return map(input) do arr
    convert_input(nn, arr)
  end
end

"""
    convert_output(::AbstractNetwork, output)

Convert an array (or number) produced by a neural network
to a standard CPU array (or number) type.
"""
function convert_output end

function convert_output_tuple(nn::AbstractNetwork, output::Tuple)
  return map(output) do arr
    convert_output(nn, arr)
  end
end

"""
    forward(::AbstractNetwork, states)

Compute the forward pass of a network on a batch of inputs.

Expect a `Float32` tensor `states` whose batch dimension is the last one.

Return a `(P, V)` triple where:

  - `P` is a matrix of size `(num_actions, batch_size)`. It is allowed
    to put weight on invalid actions (see [`evaluate`](@ref)).
  - `V` is a row vector of size `(1, batch_size)`
"""
function forward end

"""
    regularized_params(::AbstractNetwork)

Return the collection of regularized parameters of a network.
This usually excludes neuron's biases.
"""
function regularized_params end

"""
    params(::AbstractNetwork)

Return the collection of trainable parameters of a network.
"""
function params end

"""
    gc(::AbstractNetwork)

Perform full garbage collection and empty the GPU memory pool.
"""
function gc end

# Optimizers and training

"""
    OptimiserSpec

Abstract type for an optimiser specification.
"""
abstract type OptimiserSpec end

"""
    CyclicNesterov(; lr_base, lr_high, lr_low, momentum_low, momentum_high)

SGD optimiser with a cyclic learning rate and cyclic Nesterov momentum.

  - During an epoch, the learning rate goes from `lr_low`
    to `lr_high` and then back to `lr_low`.
  - The momentum evolves in the opposite way, from high values
    to low values and then back to high values.
"""
@kwdef struct CyclicNesterov <: OptimiserSpec
  lr_base :: Float32
  lr_high :: Float32
  lr_low  :: Float32
  momentum_low :: Float32
  momentum_high :: Float32
end

"""
    Adam(;lr)

Adam optimiser.
"""
@kwdef struct Adam <: OptimiserSpec
  lr :: Float32
end

"""
    train!(callback, ::AbstractNetwork, opt::OptimiserSpec, loss, batches, n)

Update a given network to fit some data.
  - [`opt`](@ref OptimiserSpec) specifies which optimiser to use.
  - `loss` is a function that maps a batch of samples to a tracked real.
  - `data` is an iterator over minibatches.
  - `n` is the number of minibatches. If `length` is defined on `data`,
     we must have `length(data) == n`. However, not all finite
     iterators implement `length` and thus this argument is needed.
  - `callback(i, loss)` is called at each step with the batch number `i`
     and the loss on last batch.
"""
function train! end

#####
##### Derived functions
#####

"""
    num_parameters(::AbstractNetwork)

Return the total number of parameters of a network.
"""
function num_parameters(nn::AbstractNetwork)
  return sum(length(p) for p in params(nn))
end

"""
    num_regularized_parameters(::AbstractNetwork)

Return the total number of regularized parameters of a network.
"""
function num_regularized_parameters(nn::AbstractNetwork)
  return sum(length(p) for p in regularized_params(nn))
end

"""
    mean_weight(::AbstractNetwork)

Return the mean absolute value of the regularized parameters of a network.
"""
function mean_weight(nn::AbstractNetwork)
  sw = sum(sum(abs.(p)) for p in regularized_params(nn))
  sw = convert_output(nn, sw)
  return sw / num_regularized_parameters(nn)
end

"""
    evaluate(network::AbstractNetwork, states, actions_mask)

Evaluate a batch of states. This function is a wrapper
on [`forward`](@ref) that puts a zero weight on invalid actions.

# Arguments

  - `states` is a tensor whose last dimension has size `bach_size`
  - `actions_mask` is a binary matrix of size `(num_actions, batch_size)`

# Return

Return a `(P, V, Pinv)` triple where:

  - `P` is a matrix of size `(num_actions, batch_size)`.
  - `V` is a row vector of size `(1, batch_size)`.
  - `Pinv` is a row vector of size `(1, batch_size)`
     that indicates the total probability weight put by the network
     on invalid actions for each sample.

All tensors manipulated by this function have elements of type `Float32`.
"""
function evaluate(nn::AbstractNetwork, state, actions_mask)
  p, v = forward(nn, state)
  p = p .* actions_mask
  sp = sum(p, dims=1)
  p = p ./ (sp .+ eps(eltype(p)))
  p_invalid = 1 .- sp
  return (p, v, p_invalid)
end

to_singletons(x) = reshape(x, size(x)..., 1)
from_singletons(x) = reshape(x, size(x)[1:end-1])

function (nn::AbstractNetwork)(game, state)
  actions_mask = GI.actions_mask(GI.new_env(game, state))
  x = GI.vectorize_state(game, state)
  a = Float32.(actions_mask)
  xnet, anet = to_singletons.(convert_input_tuple(nn, (x, a)))
  net_output = evaluate(nn, xnet, anet)
  p, v, _ = from_singletons.(convert_output_tuple(nn, net_output))
  return (p[actions_mask], v[1])
end

"""
    evaluate_batch(::AbstractNetwork, game, batch)

Evaluate a batch of positions at once.
"""
function evaluate_batch(nn::AbstractNetwork, game, batch)
  X = Util.superpose((GI.vectorize_state(game, b) for b in batch))
  A = Util.superpose((GI.actions_mask(GI.new_env(game, b)) for b in batch))
  Xnet, Anet = convert_input_tuple(nn, (X, Float32.(A)))
  P, V, _ = convert_output_tuple(nn, evaluate(nn, Xnet, Anet))
  return [(P[A[:,i],i], V[1,i]) for i in eachindex(batch)]
end

"""
    copy(::AbstractNetwork; on_gpu, test_mode)

A copy function that also handles CPU/GPU transfers and
test/train mode switches.
"""
function copy(network::AbstractNetwork; on_gpu, test_mode)
  network = Base.copy(network)
  network = on_gpu ? to_gpu(network) : to_cpu(network)
  set_test_mode!(network, test_mode)
  return network
end

end
