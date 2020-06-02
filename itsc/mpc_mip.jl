using Convex

using SCS
using COSMO
using CSDP
using SDPA
using ECOS

#using OSQP
#using GLPK

#using Gurobi # License required
#using Mosek, MosekTools # License required www.mosek.com

using LinearAlgebra
using Plots

visu_graph = true
first_plot = true

solvers = Dict("SCS" => ()->SCS.Optimizer(), 
               "COSMO" => ()->COSMO.Optimizer(),
               "CSDP" => ()->CSDP.Optimizer(),
               "SDPA" => ()->SDPA.Optimizer(),
               #"Gurobi" => ()->Gurobi.Optimizer(), # Fail ...
               #"OSQP" => ()->OSQP.Optimizer(), # Fail ...
               #"GLPK" => ()->GLPK.Optimizer(), # does not support QP obj
               #"Mosek" => ()->Mosek.Optimizer(), # Fail ... TOO SLOW PROGRESS
               "ECOS" => ()->ECOS.Optimizer())

pkg = "ECOS"
solver = solvers[pkg]

# -----------------------------------
# MPC with Mixed Integer Programming
# -----------------------------------

# We use Mosek to deal with Quadratic cost fct + MIP
# Open source GPLK does not deal with Quadratic cost fct
# Another commercial alternative could be: Gurobi

# We will use Boolean Variables to deal with disjunctive constraints (OR)
# Cf https://optimization.mccormick.northwestern.edu/index.php/Disjunctive_inequalities


mutable struct MpcPath1d
	# MPC planning horizon
	T::Int64 # T horizon: number of time steps
	dt::Float64 # Time Step length

	# Quadratic cost function
	Q::Array{Float64,2}
	R::Array{Float64,2}

	# Feasibility constraints
	smin::Float64 # min pos
	smax::Float64 # max pos
	vmin::Float64 # min speed
	vmax::Float64 # max speed
	umin::Float64 # min acceleration/command
	umax::Float64 # max acceleration/command

	# Safety constraints
	dsaf::Float64 # safety distance wrt other vehicles

	# Dynamic constraints (Constant Acceleration model)
	Ad::Array{Float64,2} # [1 dt; 0 1]
	Bd::Array{Float64,1} # [dt^2/2 dt]

	# # --- NB: note that so far, all constraints are LINEAR ---

	xref::Vector{Float64} # our target position and speed (ref)
	uref::Vector{Float64} # our target control (want to stabilize at u=0)
	xinit::Vector{Float64} # our initial position and speed

	# NB: note that without the obstacles constraints
	# we could deal with linear obj and linear constraints
	# => a simplex algo would be guaranteed to find global optimum (TODO ?)

	# Obstacles: list (1D array) of (t,s) tuples
	# Define when and where an object will cross our path
	# This is based on a prediction: 1 obj may lead to multiple (t,s) tuples
	# to account for uncertainty. NB: could be more efficient to increase dsaf
	obstacles::Array{Tuple{Float64, Float64}, 1}

	nvars_dt::Int64 # Number of variables PER Time Step (2 state vars + 1 ctlr var)

	MpcPath1d(T=20, dt=0.250,
			  Q=Diagonal([0.2, 10]), R=Diagonal([0.001]), # Normalize <=10 the coefficients
			  smin=0.0, smax=1000.0,
			  vmin=0.0, vmax=25.0, # Between 0 and 25 m.s-1
			  umin=-4.0, umax=2.0, # Between -4 and 2 m.s-2
			  dsaf=10.0,
			  Ad=[1.0 dt; 0 1],
			  Bd=[0.5*dt^2, dt],

			  # NB: xref, uref, xinit, obstacles are expected to be changed/updated everytime we plan (TODO)
			  xref=[100.0, 20.0], # Target pos=100 at v=20 m.s-1
			  uref=[0.0],
			  xinit=[0.0, 20.0], # Start at s=0 with speed v=20 m.s-1
			  obstacles=[(2.0, 40), (3.0, 80)], # In 2 sec a crossing vehicle at s=40 m

			  nvars_dt=3 # x=[s,sd] u=[sdd]
			  ) = new(T,dt,Q,R,smin,smax,vmin,vmax,umin,umax,dsaf,Ad,Bd,xref,uref,xinit,obstacles,nvars_dt)
end



function path1d_cost(mpc::MpcPath1d, x::Variable)
	cost = 0

	# stage cost
	for k in range(1, step=mpc.nvars_dt, length=mpc.T-1)
		xk, uk = x[k:k+1], x[k+2]
		cost += quadform(xk - mpc.xref, mpc.Q)
		cost += quadform(uk - mpc.uref, mpc.R)
	end

	xT, uT = x[end-2:end-1], [x[end]]
	cost += quadform(xT - mpc.xref, mpc.Q)
	cost /= (mpc.nvars_dt * mpc.T) # make the cost num_steps independant

	return cost
end

function path1d_constraints(mpc::MpcPath1d, x::Variable, p)
	# --- Equality constraints ---
	p.constraints += [x[1] == mpc.xinit[1]]
	p.constraints += [x[2] == mpc.xinit[2]]

	dt = mpc.dt

	# Time Steps: 2 .. T Dynamics Cosntraints
	for k in range(1+mpc.nvars_dt, step=mpc.nvars_dt, length=mpc.T-1)
		# Dynamic Constraints: Constant Acceleration Model in between 2 Time Steps
		kp = k - mpc.nvars_dt # p for previous
		p.constraints += [x[k] == x[kp] + dt*x[kp+1] + 0.5*dt^2*x[kp+2]]
		p.constraints += [x[k+1] == x[kp+1] + dt*x[kp+2]]
	end

	# --- Inequality constraints ---
	p.constraints += [mpc.umin <= x[3], x[3] <= mpc.umax]

	# Time Steps: 2 .. T
	for k in range(1+mpc.nvars_dt, step=mpc.nvars_dt, length=mpc.T-1)
		p.constraints += [mpc.smin <= x[k], x[k] <= mpc.smax]
		p.constraints += [mpc.vmin <= x[k+1], x[k+1] <= mpc.vmax]
		p.constraints += [mpc.umin <= x[k+2], x[k+2] <= mpc.umax]
	end

	# TODO Obstacles constraints
	# obstacle constraint (1st tests)
	for obstacle in mpc.obstacles
		tcross, scross = obstacle
		tcrossd = floor(Int, tcross/mpc.dt)
		if (tcrossd >= 1) && (tcrossd <= mpc.T)
			# if within MPC horizon
			# BUG FIX: NOT -1 ... Index starts at 1 in Julia ... 
			k = tcrossd * mpc.nvars_dt + 1
			p.constraints += [x[k] <= scross - 1.1*mpc.dsaf]
		end
	end

end

function path1d_init(mpc::MpcPath1d)

	x0 = zeros(mpc.T * mpc.nvars_dt)
	v = mpc.xinit[2]

	# Time Step: 1
	x0[1:2], x0[3] = mpc.xinit, 0 # init [pos,speed], [accel]

	# Time Steps: 2 .. T
	for k in range(1+mpc.nvars_dt, step=mpc.nvars_dt, length=mpc.T-1)
		x0[k] = x0[k - mpc.nvars_dt] + v * mpc.dt
		x0[k+1] = v
		x0[k+2] = 0
	end

	return x0
end


mpc = MpcPath1d()


plot(title="s-t graph", xlabel=("t (sec)"), ylabel=("s (m)"), marker=2, legend=:topleft)

for (pkg, solver) in solvers
	global first_plot

	runtime = 0
	x = Variable(60)
	#b = Variable(1, :Bin)
	cost = path1d_cost(mpc, x)
	#p = minimize(cost+b)
	p = minimize(cost)
	path1d_constraints(mpc, x, p)
	x0 = path1d_init(mpc)

	for i in 1:2 # 2 times to get runtime for compiled version
		println("start solver...")
		x.value = x0
		println("x0=$x0")
	
		runtime = @elapsed solve!(p, solver, warmstart=true)
	
		println("status=", p.status)
		println("cost=", round(p.optval, digits=2))
		println("x=", round.(x.value, digits=2))
		runtime = convert(Int64, round(1000*runtime))
		println("runtime=$runtime ms")
	end
	
	if visu_graph
		function circleShape(t, s, Δt, Δs)
			θ = LinRange(0, 2*π, 500)
			t .+ Δt*sin.(θ), s .+ Δs*cos.(θ)
		end
	
		x = x.value
	
		s = [x[i] for i in (1:3:length(x))]
		t = collect((1:length(s))) .- 1
		t = t .* mpc.dt
	
		plot!(t, s, label="$(pkg) path ($runtime ms)", marker=2)
	
		if first_plot
			for (i, obs) in enumerate(mpc.obstacles)
				tt, s = obs
				plot!(circleShape(tt, s, mpc.dt, mpc.dsaf), st=[:shape,], lw=0.5, linecolor=:black, fillalpha=0.2, label="obstacle $i")
			end
	
			s = [x0[i] for i in (1:3:length(x0))]
			plot!(t, s, label="initial path", marker=2)
			first_plot = false
		end
	
	end
end

visu_graph && savefig("st_graph_solvers.png")
