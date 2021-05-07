
## features 

"""
    get_front_neighbor(env::MergingEnvironment, scene::Scene, egoid::Int64)
returns the front neighbor of `egoid` in its lane. 
It returns an object of type `NeighborLongitudinalResult`
"""
function get_front_neighbor(env::MergingEnvironment, scene::Scene, egoid::Int64)
    ego_ind = findfirst(egoid, scene)
    ego = scene[ego_ind]
    # merge neighbor
    ego_lane = get_lane(env.roadway, ego)
    if ego_lane == main_lane(env)
        fore_res = find_neighbor(scene, env.roadway, ego)
    else
        posF = Frenet(env.merge_proj, env.roadway)
        ego_proj = Entity(VehicleState(posF, env.roadway, vel(ego)), ego.def, ego.id)
        fore_res = find_neighbor(scene, env.roadway, ego_proj)
    end
end

"""
    get_neighbors(env::MergingEnvironment, scene::Scene, egoid::Int64)
returns the following neighbors id and relative distance (if they exist) 
    - the front neighbor of vehicle `egoid`
    - the vehicle right behind the merge point (if `egoid` is on the main lane)
    - the front neighbor of the projection of `egoid` on the main lane 
    - the rear neighbor of the projection of `egoid` on the merge lane 
"""
function get_neighbors(env::MergingEnvironment, scene::Scene, egoid::Int64)
    ego_ind = findfirst(egoid, scene)
    ego = scene[ego_ind]

    #front neighbor 
    front = get_front_neighbor(env, scene, egoid)

    # merge neighbor
    ego_lane = get_lane(env.roadway, ego)
    if ego_lane == main_lane(env)
        merge_rear = find_neighbor(scene, env.roadway, ego, rear=true)
    else
        posF = Frenet(env.merge_proj, env.roadway)
        ego_proj = Entity(VehicleState(posF, env.roadway, vel(ego)), ego.def, ego.id)
        merge_rear = find_neighbor(scene, env.roadway, ego_proj, rear=true)
    end
    # two closest car in main lane
    fore_main = find_neighbor(scene, env.roadway, ego, lane=main_lane(env))
    rear_main = find_neighbor(scene, env.roadway, ego, lane=main_lane(env), rear=true)
    return front, merge_rear, fore_main, rear_main
end

"""
    dist_to_merge(env::MergingEnvironment, veh::Entity)
returns the distance to the merge point.
"""
function dist_to_merge(env::MergingEnvironment, veh::Entity)
    lane = get_lane(env.roadway, veh)
    if lane == main_lane(env)
        frenet_merge = get_frenet_relative_position(veh.state.posG, env.merge_index, env.roadway)
        dist = frenet_merge.Δs
    else
        dist = veh.state.posF.s - get_end(lane) 
    end
    return dist
end

"""
    time_to_merge(env::MergingEnvironment, veh::Entity, a::Float64 = 0.0)
return the time to reach the merge point using constant acceleration prediction. 
If the acceleration, `a` is not specified, it performs a constant velocity prediction.
"""
function time_to_merge(env::MergingEnvironment, veh::Entity, a::Float64 = 0.0)
    d = -dist_to_merge(env, veh)
    v = veh.state.v
    t = Inf
    if isapprox(a, 0.0) 
        t =  d/veh.state.v 
    else
        delta = v^2 + 2.0*a*d
        if delta < 0.0
            t = Inf
        else
            t = (-v + sqrt(delta)) / a 
        end
        if t < 0.0
            t = Inf
        end
    end
    return t
end

"""
    find_merge_vehicle(env::MergingEnvironment, scene::Scene)
returns the id of the merging vehicle if there is a vehicle on the merge lane.
"""
function find_merge_vehicle(env::MergingEnvironment, scene::Scene)
    for veh in scene 
        lane = get_lane(env.roadway, veh)
        if lane == merge_lane(env)
            return veh
        end
    end
    return nothing
end

"""
    constant_acceleration_prediction(env::MergingEnvironment, veh::Entity, acc::Float64, time::Float64, v_des::Float64)
returns the state of vehicle `veh` after time `time` using a constant acceleration prediction. 

# inputs
- `env::MergingEnvironment` the environment 
- `veh::Entity` the initial state of the vehicle
- `acc::Float64` the current acceleration of the vehicle 
- `time::Float64` the prediction horizon 
- `v_des::Float64` the desired speed of the vehicle (assumes that the vehicle will not exceed that speed)
"""
function constant_acceleration_prediction(env::MergingEnvironment, 
                                          veh::Entity,
                                          acc::Float64,
                                          time::Float64,
                                          v_des::Float64)
        # act = LaneFollowingAccel(acc)
        # vehp = propagate(veh, act, env.roadway, time, true)
        v1 = veh.state.v
        v2 = clamp(veh.state.v + acc*time , 0.0, v_des)
        if acc ≈ 0.0
            Δs = v1*time
        else
            Δs = (v2^2 - v1^2) / (2*acc)
        end
        Δs = max(0., Δs)
        sp = veh.state.posF.s + Δs
        lane = get_lane(env.roadway, veh)
        vehp = vehicle_state(sp, lane, v2, env.roadway)
        return Entity(vehp, veh.def, veh.id)
end

"""
    distance_projection(env::MergingEnvironment, veh::Entity)
Performs a projection of `veh` onto the main lane. It returns the longitudinal position of the projection of `veh` on the main lane. 
The projection is computing by conserving the distance to the merge point.
"""
function distance_projection(env::MergingEnvironment, veh::Entity)
    if get_lane(env.roadway, veh) == main_lane(env)
        return veh.state.posF.s 
    else
        dm = -dist_to_merge(env, veh)
        return env.roadway[env.merge_index].s - dm
    end
end

"""
    collision_time(env::MergingEnvironment, veh::Entity, mergeveh::Entity, acc_merge::Float64, acc_min::Float64)
compute the collision time between two vehicles assuming constant acceleration.
"""
function collision_time(env::MergingEnvironment, 
                        veh::Entity, 
                        mergeveh::Entity, 
                        acc_merge::Float64, 
                        acc_min::Float64)
    rel_vel = mergeveh.state.v - veh.state.v
    rel_pos = distance_projection(env, mergeveh) - distance_projection(env, veh)
    rel_acc = acc_merge - acc_min 
    delta = rel_vel^2 - 2*rel_acc*rel_pos
    if delta < 0.0
        return nothing 
    elseif rel_acc != 0.0
        t_coll = (-rel_vel + sqrt(delta))/rel_acc
        return t_coll
    elseif rel_vel != 0.0 
        t_coll = - rel_pos / rel_vel
        return t_coll
    else
        t_coll = nothing
        return t_coll
    end
end

"""
    braking_distance(v::Float64, t_coll::Float64, acc::Float64)
computes the distance to reach a velocity of 0. at constant acceleration `acc` in time `t_coll` with initial velocity `v`
"""
function braking_distance(v::Float64, t_coll::Float64, acc::Float64)
    brake_dist = v*t_coll + 0.5*acc*t_coll^2
    return brake_dist
end

"""
    AutomotiveSimulator.propagate(veh::Entity{VehicleState,D,I}, action::LaneFollowingAccel, roadway::Roadway, ΔT::Float64, nobackup::Bool) where {D,I}
A propagate method for `LaneFollowingAccel` that prevents the car from backing up in `nobackup = true`.
"""
function AutomotiveSimulator.propagate(veh::Entity{VehicleState,D,I}, action::LaneFollowingAccel, roadway::Roadway, ΔT::Float64, nobackup::Bool) where {D,I}

    a_lon = action.a

    ds = veh.state.v

    ΔT² = ΔT*ΔT

    Δs = ds*ΔT + 0.5*a_lon*ΔT²
    v₂ = ds + a_lon*ΔT

    if nobackup
        Δs = max(Δs, 0.0)
        v₂ = max(v₂, 0.0)
    end

    roadind = move_along(veh.state.posF.roadind, roadway, Δs)
    posG = roadway[roadind].pos
    posF = Frenet(roadind, roadway, t=veh.state.posF.t, ϕ=veh.state.posF.ϕ)
    VehicleState(posG, posF, v₂)
end

"""
    wrap_around(env::MergingEnvironment, veh::Entity)
respawn vehicle at the beginning of the main lane
"""
function wrap_around(env::MergingEnvironment, veh::Entity)
    lane = get_lane(env.roadway, veh)
    s_end = get_end(lane)
    s = veh.state.posF.s
    if s >= s_end - WRAP_AROUND_TOL && lane == main_lane(env) && veh.id != EGO_ID
        veh_state = vehicle_state(0.0, main_lane(env), veh.state.v, env.roadway)
        return Entity(veh_state,veh.def, veh.id)
    end
    return veh
end

# function AutomotiveSimulator.tick!(
#     scene::EntityFrame{S,D,I},
#     roadway::R,
#     actions::Vector{A},
#     Δt::Float64,
#     nobackup::Bool
#     ) where {S,D,I,R,A}

#     for i in 1 : length(scene)
#         veh = scene[i]
#         state′ = propagate(veh, actions[i], roadway, Δt, nobackup)
#         scene[i] = Entity(state′, veh.def, veh.id)
#     end

#     return scene
# end
