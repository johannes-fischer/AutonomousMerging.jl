## Generative Merging MDP model

const HARD_BRAKE = 1
const RELEASE = 7
const WRAP_AROUND_TOL = 2.0 # when vehicles reach the end of the main lane - WRAP_AROUND_TOL they are spawned at the beginning

"""
    AugScene
Driving scene augmented with information about the ego vehicle
"""
struct AugScene{E}
    scene::Scene{E}
    ego_info::NamedTuple{(:acc,), Tuple{Float64}}
end

# Dummy type since the action is given by the policy
mutable struct EgoDriver{A} <: DriverModel{A}
    a::A
end

Base.rand(rng::AbstractRNG, model::EgoDriver) = model.a
AutomotiveSimulator.observe!(m::EgoDriver, s::Scene, roadway::Roadway, egoid::Int64) = m

"""
    GenerativeMergingMDP

A simulation environment for a highway merging scenario. Implemented using POMDPs.jl 

# Parameters
    - `env::MergingEnvironment = MergingEnvironment(main_lane_angle = 0.0, merge_lane_angle = pi/7)`
    - `n_cars_main::Int64 = 1`
    - `n_cars_merge::Int64 = 1`
    - `n_agents::Int64 = n_cars_main + n_cars_merge`
    - `max_cars::Int64 = 16`
    - `min_cars::Int64 = 0`
    - `car_def::VehicleDef = VehicleDef()`
    - `dt::Float64 = 0.5 # time step`
    - `jerk_levels::SVector{5, Float64} = SVector(-1, -0.5, 0, 0.5, 1.0)`
    - `accel_levels::SVector{6, Float64} = SVector(-4.0, -2.0, -1.0, 0.0, 1.0, 2.0)`
    - `max_deceleration::Float64 = -4.0`
    - `max_acceleration::Float64 = 3.5`
    - `comfortable_acceleration::Float64 = 2.0`
    - `discount_factor::Float64 = 0.95`
    - `ego_idm::IntelligentDriverModel = IntelligentDriverModel(σ=0.0, v_des=env.main_lane_vmax)`
    - `default_driver_model::DriverModel{LaneFollowingAccel} = IntelligentDriverModel(v_des=env.main_lane_vmax)`
    - `observe_cooperation::Bool = false`
    - `observe_speed::Bool = true`
    - `traffic_speed::Symbol = :mixed`
    - `random_n_cars::Bool = false`
    - `driver_type::Symbol = :random` can be :binary, or :aggressive, or :cooperative
    - `max_burn_in::Int64 = 20`
    - `min_burn_in::Int64 = 10`
    - `initial_ego_velocity::Float64 = 10.0`
    - `initial_velocity::Float64 = 5.0`
    - `initial_velocity_std::Float64 = 1.0`
    - `main_lane_slots::LinRange{Float64} = LinRange(0.0, env.main_lane_length + env.after_merge_length, max_cars)`
    - `collision_cost::Float64 = -1.0`
    - `goal_reward::Float64 = 1.0`
    - `hard_brake_cost::Float64 = 0.0`
"""
@with_kw mutable struct GenerativeMergingMDP <: MDP{AugScene, Int64}
    env::MergingEnvironment = MergingEnvironment(main_lane_angle = 0.0, merge_lane_angle = pi/7)
    n_cars_main::Int64 = 1
    n_cars_merge::Int64 = 1
    n_agents::Int64 = n_cars_main + n_cars_merge
    max_cars::Int64 = 16
    min_cars::Int64 = 0
    car_def::VehicleDef = VehicleDef()
    dt::Float64 = 0.5 # time step
    jerk_levels::SVector{5, Float64} = SVector(-1, -0.5, 0, 0.5, 1.0)
    accel_levels::SVector{6, Float64} = SVector(-4.0, -2.0, -1.0, 0.0, 1.0, 2.0)
    max_deceleration::Float64 = -4.0
    max_acceleration::Float64 = 3.5
    comfortable_acceleration::Float64 = 2.0
    discount_factor::Float64 = 0.95
    ego_idm::IntelligentDriverModel = IntelligentDriverModel(σ=0.0, v_des=env.main_lane_vmax)
    default_driver_model::DriverModel{LaneFollowingAccel} = IntelligentDriverModel(v_des=env.main_lane_vmax)
    observe_cooperation::Bool = false
    observe_speed::Bool = true
    # initial state params
    traffic_speed::Symbol = :mixed
    random_n_cars::Bool = false
    driver_type::Symbol = :random
    max_burn_in::Int64 = 20
    min_burn_in::Int64 = 10
    initial_ego_velocity::Float64 = 10.0
    initial_velocity::Float64 = 5.0
    initial_velocity_std::Float64 = 1.0
    main_lane_slots::LinRange{Float64} = LinRange(0.0, 
                                            env.main_lane_length + env.after_merge_length,
                                            max_cars)
    # reward params 
    collision_cost::Float64 = -1.0
    goal_reward::Float64 = 1.0
    hard_brake_cost::Float64 = 0.0
    
    # internal states 
    driver_models::Dict{Int64, DriverModel} = Dict{Int64, DriverModel}(EGO_ID=>EgoDriver(LaneFollowingAccel(0.0)))    
end

POMDPs.discount(mdp::GenerativeMergingMDP) = mdp.discount_factor
POMDPs.actions(::GenerativeMergingMDP) = 1:7
POMDPs.actionindex(mdp::GenerativeMergingMDP, a::Int64) = a

function POMDPs.initialstate(mdp::GenerativeMergingMDP)
    ImplicitDistribution() do rng
        if mdp.random_n_cars
            mdp.n_cars_main = rand(rng, mdp.min_cars:mdp.max_cars)
        end
        mdp.driver_models = Dict{Int64, DriverModel}(EGO_ID=>EgoDriver(LaneFollowingAccel(0.0)))
        start_positions = sample(rng, mdp.main_lane_slots, mdp.n_cars_main, replace=false)   

        start_velocities = mdp.initial_velocity .+ mdp.initial_velocity_std*randn(rng, mdp.n_cars_main)
        ego = initial_merge_car_state(mdp, rng, EGO_ID)
        ego_acc_0 = 0.0
        scene = Scene(typeof(ego), mdp.n_cars_main + 1)
        for i=1:mdp.n_cars_main
            id = EGO_ID + i
            veh_state = vehicle_state(start_positions[id - EGO_ID], main_lane(mdp.env),
            start_velocities[id - EGO_ID], mdp.env.roadway)
            veh = Entity(veh_state, mdp.car_def, id)
            push!(scene, veh)
            mdp.driver_models[id] = CooperativeIDM()
            if mdp.traffic_speed == :mixed
                v_des = sample(rng, [4.0, 5., 6.0], Weights([0.2, 0.3, 0.5]))
            elseif mdp.traffic_speed == :fast
                v_des = 15.0
            end
            set_desired_speed!(mdp.driver_models[id], v_des)
            if mdp.driver_type == :random
                mdp.driver_models[id].c = rand(rng, 0:0.01:1) # change cooperativity
            elseif mdp.driver_type == :binary 
                mdp.driver_models[id].c = sample(rng, [0,1], Weights([0.9, 0.1])) # change cooperativity
            elseif mdp.driver_type == :aggressive
                mdp.driver_models[id].c = 0.0
            elseif mdp.driver_type == :cooperative
                mdp.driver_models[id].c = 1.0
            end   
        end
        # burn in 
        burn_in =rand(rng, mdp.min_burn_in:mdp.max_burn_in)
        next_scene = Scene(eltype(scene), length(scene))
        for t=1:burn_in
            for (i, veh) in enumerate(scene)

                observe!(mdp.driver_models[veh.id], scene, mdp.env.roadway, veh.id)
                a = rand(rng, mdp.driver_models[veh.id])

                veh_state_p  = propagate(veh, a, mdp.env.roadway, mdp.dt, false)
                entity = wrap_around(mdp.env, Entity(veh_state_p, veh.def, veh.id))
                push!(next_scene, entity)
            end
            copyto!(scene, next_scene)
            empty!(next_scene)

        end
        push!(scene, ego)

        return AugScene(scene, (acc=ego_acc_0,))
    end
end    

function POMDPs.reward(mdp::GenerativeMergingMDP, s::AugScene, a::Int64, sp::AugScene)
    egop = get_by_id(sp.scene, EGO_ID)
    r = 0.0
    if reachgoal(mdp, egop)
       r += mdp.goal_reward    
    elseif collision_checker(sp.scene, EGO_ID)
        r += mdp.collision_cost
    end
    if caused_hard_brake(mdp, sp.scene)
        r += mdp.hard_brake_cost
    end
    return r
end

function POMDPs.reward(pomdp::FullyObservablePOMDP{AugScene,Int64}, s::AugScene, a::Int64, sp::AugScene)
    return reward(pomdp.mdp, s, a, sp)
end

function POMDPs.isterminal(mdp::GenerativeMergingMDP, s::AugScene)
    return collision_checker(s.scene, EGO_ID) || reachgoal(mdp, get_by_id(s.scene, EGO_ID))
end

function POMDPs.gen(mdp::GenerativeMergingMDP, s::AugScene, a::Int64, rng::AbstractRNG)
    scene = s.scene

    # update driver models 
    mdp.driver_models[EGO_ID].a = action_map(mdp, s.ego_info.acc, a)
    ego_acc = mdp.driver_models[EGO_ID].a.a
    for i=EGO_ID+1:EGO_ID+mdp.n_cars_main
        mdp.driver_models[i].other_acc = s.ego_info.acc
    end

    # simulate one step
    next_scene = Scene(eltype(scene), length(scene))
    for veh in scene
        observe!(mdp.driver_models[veh.id], scene, mdp.env.roadway, veh.id)
        a = rand(rng, mdp.driver_models[veh.id])

        veh_state_p  = propagate(veh, a, mdp.env.roadway, mdp.dt, false)
        entity = wrap_around(mdp.env, Entity(veh_state_p, veh.def, veh.id))
        push!(next_scene, entity)
    end

    return (sp=AugScene(next_scene, (acc=ego_acc,)), )
end

""" 
    extract_features(mdp::GenerativeMergingMDP, s::AugScene)
extract a feature vector from AugScene
"""
function extract_features(mdp::GenerativeMergingMDP, s::AugScene)
    # @show keys(mdp.driver_models)
    scene = s.scene
    env = mdp.env
    features = -3*ones(15)
    ego_ind = findfirst(EGO_ID, scene)
    ego = scene[ego_ind]


    # distance to merge point 
    s_ego = dist_to_merge(env, ego)
    v_ego = ego.state.v
    features[1] = s_ego
    features[2] = v_ego
    features[3] = s.ego_info.acc
    # get neighbors 
    fore, merge, fore_main, rear_main = get_neighbors(env, scene, EGO_ID)

    # front neighbor
    features[6] = 0.0
    if fore.ind !== nothing
        fore_id = scene[fore.ind].id
        v_oth = scene[fore.ind].state.v
        headway = fore.Δs
        features[4] = headway
        if mdp.observe_speed
            features[5] = v_oth
        else
            features[5] = 0.0
        end
        if mdp.observe_cooperation
            features[6] = mdp.driver_models[fore_id].c
        else
            features[6] = 0.
        end
    end


    # two closest cars in main lane
    features[9] = 0.0
    if fore_main.ind !== nothing 
        fore_main_id = scene[fore_main.ind].id
        v_oth_main_fore = scene[fore_main.ind].state.v
        headway_main_fore = fore_main.Δs
        features[7] = headway_main_fore
        if mdp.observe_speed
            features[8] = v_oth_main_fore
        else
            features[8] = 0.0
        end
        if mdp.observe_cooperation
            features[9] = mdp.driver_models[fore_main_id].c
        else
            features[9] = 0.
        end
    end
    features[12] = 0.0
    if rear_main.ind !== nothing 
        rear_main_id = scene[rear_main.ind].id
        v_oth_main_rear = scene[rear_main.ind].state.v
        headway_main_rear = rear_main.Δs
        features[10] = headway_main_rear
        if mdp.observe_speed
            features[11] = v_oth_main_rear
        else
            features[11] = 0.0
        end
        if mdp.observe_cooperation
            features[12] = mdp.driver_models[rear_main_id].c
        else
            features[12] = 0.
        end
    end

    # rear car to the merge point 
    features[15] = 0.0
    if merge.ind !== nothing
        merge_id = scene[merge.ind].id
        v_oth = scene[merge.ind].state.v
        headway = merge.Δs
        features[13] = headway
        if mdp.observe_speed
            features[14] = v_oth
        else
            features[14] = 0.0
        end
        if mdp.observe_cooperation
            features[15] = mdp.driver_models[merge_id].c
        else
            features[15] = 0.
        end
    end
    return features
end

""" 
    normalize_features!(mdp::GenerativeMergingMDP, features::Vector{Float64})
normalize a feature vector extracted from a scene
"""
function normalize_features!(mdp::GenerativeMergingMDP, features::Vector{Float64})
    features[1] /=  mdp.env.main_lane_length
    features[2] /=  mdp.env.main_lane_vmax
    features[3] /=   mdp.max_deceleration
    features[4] /= mdp.env.main_lane_length
    features[5] /=  mdp.env.main_lane_vmax
    features[6] /= 1.
    features[7] /= mdp.env.main_lane_length
    features[8] /=   mdp.env.main_lane_vmax
    features[9] /= 1.
    features[10] /= mdp.env.main_lane_length
    features[11] /=  mdp.env.main_lane_vmax
    features[12] /= 1.
    features[13] /= mdp.env.main_lane_length
    features[14] /=  mdp.env.main_lane_vmax
    features[15] /= 1.

    return features
end

"""
     unnormalize_features!(mdp::GenerativeMergingMDP, features::Vector{Float64})
rescale feature vector
"""
function unnormalize_features!(mdp::GenerativeMergingMDP, features::Vector{Float64})
    features[1]  *=  mdp.env.main_lane_length
    features[2]  *=  mdp.env.main_lane_vmax
    features[3]  *=   mdp.max_deceleration
    features[4]  *= mdp.env.main_lane_length
    features[5]  *=  mdp.env.main_lane_vmax
    features[6]  *= 1.
    features[7]  *= mdp.env.main_lane_length
    features[8]  *=   mdp.env.main_lane_vmax
    features[9]  *= 1.
    features[10] *= mdp.env.main_lane_length
    features[11] *=  mdp.env.main_lane_vmax
    features[12] *= 1.
    features[13] *= mdp.env.main_lane_length
    features[14] *=  mdp.env.main_lane_vmax
    features[15] *= 1.

    return features
end


function POMDPs.convert_s(::Type{V}, s::AugScene, mdp::GenerativeMergingMDP) where V<:AbstractArray
    feature_vec = extract_features(mdp, s)
    normalize_features!(mdp, feature_vec)
    return convert(V, feature_vec)
end

function POMDPs.convert_s(::Type{AugScene}, o::V, mdp::GenerativeMergingMDP) where V<:AbstractArray
    feature_vec = deepcopy(o)
    unnormalize_features!(mdp, feature_vec)
    s_ego, v_ego, s_front, v_front, s_fm, v_fm, s_rm, v_rm, s_m, v_m, a_ego = feature_vec[1:11]

    # reconstruct the scene
    scene = Scene()
    if s_ego < 0.0
        lane_ego = merge_lane(mdp.env)
        s_ego = get_end(lane_ego) + s_ego
    else
        lane_ego = main_lane(mdp.env)
        s_ego = mdp.env.roadway[mdp.env.merge_index].s + s_ego
    end
    ego = Entity(vehicle_state(s_ego, lane_ego, v_ego, mdp.env.roadway), VehicleDef(), EGO_ID)
    push!(scene, ego)

    # front neighbor
    if lane_ego == main_lane(mdp.env)
        s_front = ego.state.posF.s + s_front
    else
        s_front = mdp.env.main_lane_length + s_front
    end
    front = Entity(vehicle_state(s_front, main_lane(mdp.env), v_front, mdp.env.roadway), VehicleDef(), EGO_ID+1)
    push!(scene, front)

    # front neighbor to projection
    proj_lane = main_lane(mdp.env)
    main_lane_proj = proj(ego.state.posG, proj_lane, mdp.env.roadway)
    s_main = proj_lane[main_lane_proj.curveproj.ind, mdp.env.roadway].s
    s_fm = s_main + s_fm
    frontmain = Entity(vehicle_state(s_fm, main_lane(mdp.env), v_fm, mdp.env.roadway), VehicleDef(), EGO_ID+2) 
    push!(scene, frontmain)

    s_rm = s_main - s_rm
    rearmain = Entity(vehicle_state(s_rm, main_lane(mdp.env), v_rm, mdp.env.roadway), VehicleDef(), EGO_ID+3) 
    push!(scene, rearmain)

    if lane_ego == main_lane(mdp.env)
        s_m = ego.state.posF.s - s_m
    else
        s_m = mdp.env.main_lane_length - s_m 
    end
    merge = Entity(vehicle_state(s_m, main_lane(mdp.env), v_m, mdp.env.roadway), VehicleDef(), EGO_ID+4) 
    push!(scene, merge)
    return AugScene(scene, (acc=a_ego,))
end


## helpers

"""
    initial_merge_car_state(mdp::GenerativeMergingMDP, rng::AbstractRNG, id::Int64)
returns an Entity, at the initial state of the merging car.
"""
function initial_merge_car_state(mdp::GenerativeMergingMDP, rng::AbstractRNG, id::Int64)
    v0 = mdp.initial_velocity + mdp.initial_velocity_std*randn(rng)
    v0 = mdp.initial_ego_velocity
    veh_state = vehicle_state(0.0, merge_lane(mdp.env), v0, mdp.env.roadway)
    return Entity(veh_state, mdp.car_def, id)
end

"""
    reset_main_car_state(mdp::GenerativeMergingMDP, veh::Entity)
initialize a car at the beginning of the main lane
"""
function reset_main_car_state(mdp::GenerativeMergingMDP, veh::Entity, rng::AbstractRNG)
    v0 = mdp.initial_velocity + mdp.initial_velocity_std*randn(rng)
    veh_state = vehicle_state(0.0, main_lane(mdp.env), v0, mdp.env.roadway)
    return Entity(veh_state, mdp.car_def, veh.id)
end

"""
    reachgoal(mdp::GenerativeMergingMDP, ego::Entity)
return true if `ego` reached the goal position
"""
function reachgoal(mdp::GenerativeMergingMDP, ego::Entity)
    lane = get_lane(mdp.env.roadway, ego)
    s = ego.state.posF.s
    return lane.tag == main_lane(mdp.env).tag && s >= get_end(lane)
end

"""
    caused_hard_brake(mdp::GenerativeMergingMDP, scene::Scene)
returns true if the ego vehicle caused its rear neighbor to hard brake
"""
function caused_hard_brake(mdp::GenerativeMergingMDP, scene::Scene)
    ego_ind = findfirst(EGO_ID, scene)
    fore_res = get_neighbor_rear_along_lane(scene, ego_ind, mdp.env.roadway)
    if fore_res.ind === nothing 
        return false
    else
        return mdp.driver_models[fore_res.ind].a <= mdp.driver_models[fore_res.ind].idm.d_max
    end
end

"""
    action_map(mdp::GenerativeMergingMDP, acc::Float64, a::Int64)
maps integer to a LaneFollowingAccel
"""
function action_map(mdp::GenerativeMergingMDP, acc::Float64, a::Int64)
    if a == HARD_BRAKE
        return LaneFollowingAccel(mdp.max_deceleration)
    elseif a == RELEASE 
        return LaneFollowingAccel(0.0)
    else
        return LaneFollowingAccel(clamp(acc + mdp.jerk_levels[a-1], mdp.max_deceleration, mdp.max_acceleration))
    end
end

"""
    vehicle_state(s::Float64, lane::Lane, v::Float64, roadway::Roadway)
convenient constructor for VehicleState
"""
function vehicle_state(s::Float64, lane::Lane, v::Float64, roadway::Roadway)
    posF = Frenet(lane, s)
    return VehicleState(posF, roadway, v)
end

"""
    clamp_speed(env::MergingEnvironment, veh::Entity)
clamp the speed of `veh` between 0. and main lane vmax
"""
function clamp_speed(env::MergingEnvironment, veh::Entity)
    v = clamp(veh.state.v, 0.0, env.main_lane_vmax)
    vehstate = VehicleState(veh.state.posG, veh.state.posF, v)
    return Entity(vehstate, veh.def, veh.id)
end

"""
    spread_out_initialization(mdp::GenerativeMergingMDP, rng::AbstractRNG)
spread out vehicles on the main lane
"""
function spread_out_initialization(mdp::GenerativeMergingMDP, rng::AbstractRNG)
    start_positions = zeros(mdp.n_cars_main)
    start_positions[1] = rand(rng, mdp.main_lane_slots)
    gap_length = div(mdp.env.main_lane_length + mdp.env.after_merge_length, mdp.n_cars_main)
    main_roadway = StraightRoadway(mdp.env.main_lane_length + mdp.env.after_merge_length)
    for i=2:mdp.n_cars_main
        start_positions[i] = mod_position_to_roadway(start_positions[i-1] + gap_length, main_roadway)
    end
    return start_positions
end

"""
    global_features(mdp::GenerativeMergingMDP, s::AugScene)
extract a vector with the states of all the vehicles in AugScene
"""
function global_features(mdp::GenerativeMergingMDP, s::AugScene)
    n_features = 2*mdp.n_cars_main + 3 + mdp.n_cars_main
    features = zeros(n_features)
    ego = get_by_id(s.scene, EGO_ID)
    features[1] = dist_to_merge(mdp.env, ego)
    features[2] = ego.state.v
    features[3] = s.ego_info.acc
    @assert s.scene[1].id == EGO_ID
    for i=2:length(s.scene)
        veh = s.scene[i]
        features[3*i-2] = veh.state.posF.s
        features[3*i-1] = veh.state.v
        obs_c = 0.5
        if mdp.observe_cooperation
            obs_c = mdp.driver_models[i].c
        end
        features[3*i] = obs_c
    end
    return features 
end

function normalize_global_features!(mdp::GenerativeMergingMDP, features::Vector{Float64})
    features[1] /= mdp.env.main_lane_length
    features[2] /= mdp.env.main_lane_vmax
    features[3] /= mdp.max_deceleration
    for i=2:mdp.n_cars_main+1
        features[3*i - 2] /= mdp.env.main_lane_length
        features[3*i - 1] /= mdp.env.main_lane_vmax
    end
    return features  
end


function unnormalize_global_features!(mdp::GenerativeMergingMDP, features::Vector{Float64})
    features[1] *= mdp.env.main_lane_length
    features[2] *= mdp.env.main_lane_vmax
    features[3] *= mdp.max_deceleration
    for i=2:mdp.n_cars_main+1
        features[3*i-2] *= mdp.env.main_lane_length
        features[3*i-1] *= mdp.env.main_lane_vmax
    end
    return features  
end
