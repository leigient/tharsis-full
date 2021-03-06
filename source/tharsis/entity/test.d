//          Copyright Ferdinand Majerech 2013.
// Distributed under the Boost Software License, Version 1.0.
//    (See accompanying file LICENSE_1_0.txt or copy at
//          http://www.boost.org/LICENSE_1_0.txt)


/// A basic unittest for Tharsis.
module tharsis.entity.test;

import std.array;
import std.exception: assumeWontThrow;
import std.stdio;
import std.string;

import tharsis.entity.lifecomponent;
import tharsis.entity.componenttypeinfo;
import tharsis.entity.componenttypemanager;
import tharsis.entity.entitypolicy;
import tharsis.entity.entityid;
import tharsis.entity.entitymanager;
import tharsis.entity.entityprototype;
import tharsis.entity.lifecomponent;
import tharsis.entity.prototypemanager;
import tharsis.entity.resource;
import tharsis.entity.resourcemanager;
import tharsis.entity.scheduler;
import tharsis.defaults.components;
import tharsis.defaults.processes;
import tharsis.defaults.resources;
import tharsis.defaults.yamlsource;





/// A simple MultiComponent type for testing.
struct TestMultiComponent
{
    enum ComponentTypeID = userComponentTypeID!4;
    /// No more than 256 TestMultiComponents per entity.
    enum maxComponentsPerEntity = 256;

    /// Content of the component.
    bool value = true;
}

/// A Process type processing TestMultiComponent.
class TestMultiComponentProcess
{
public:
    alias TestMultiComponent FutureComponent;

    /// Params: life     = The LifeComponent, to test with a longer signature.
    ///         multi    = The past TestMultiComponent.
    ///         outMulti = The future TestMultiComponent.
    void process(ref const LifeComponent life, 
                 const TestMultiComponent[] multi,
                 ref TestMultiComponent[] outMulti) nothrow
    {
        outMulti = outMulti[0 .. multi.length];
        outMulti[] = multi[];
    }
}

struct TimeoutComponent
{
    enum ushort ComponentTypeID = userComponentTypeID!1;

    enum minPrealloc = 8192;

    int removeIn;

    int killEntityIn;
}

class TestRemoveComponentProcess
{
public:
    alias TimeoutComponent FutureComponent;

    void process(ref const TimeoutComponent timeout, 
                 ref TimeoutComponent* outTimeout) nothrow
    {
        if(timeout.removeIn == 0)
        {
            outTimeout = null;
            return;
        }

        *outTimeout = timeout;
        outTimeout.removeIn     = timeout.removeIn - 1;
        outTimeout.killEntityIn = timeout.killEntityIn - 1;
    }

    void process(ref const TimeoutComponent timeout, 
                 ref const PhysicsComponent physics,
                 ref TimeoutComponent* outTimeout) nothrow
    {
        if(timeout.removeIn == 0)
        {
            outTimeout = null;
            return;
        }

        *outTimeout = timeout;
        outTimeout.removeIn     = timeout.removeIn - 1;
        outTimeout.killEntityIn = timeout.killEntityIn - 1;
    }
}


struct PhysicsComponent
{
    enum ushort ComponentTypeID = userComponentTypeID!2;

    enum minPrealloc = 16384;

    enum minPreallocPerEntity = 1.0;

    @("relative", "someOtherAttrib") float x;
    @("relative") float y;
    @("relative") float z;
}

class TestLifeProcess
{
public:
    alias LifeComponent FutureComponent;

    void process(ref const TimeoutComponent timeout, 
                 ref const LifeComponent life,
                 out LifeComponent outLife) nothrow
    {
        outLife = life;
        if(timeout.killEntityIn == 0) 
        {
            writeln("KILLING ENTITY").assumeWontThrow;
            outLife.alive = false; 
        }
    }

    void process(ref const LifeComponent life, out LifeComponent outLife) nothrow
    {
        outLife = life;
    }
}

class TestNoOutputProcess
{
public:
    void process(ref const LifeComponent life) nothrow
    {
        /*writeln("TestNoOutputProcess: ", life);*/
    }
}

void realMain()
{   
    writeln(q{
    ==========
    MAIN START
    ==========
    });

    auto compTypeMgr = new ComponentTypeManager!YAMLSource(YAMLSource.Loader());
    compTypeMgr.registerComponentTypes!TimeoutComponent();
    compTypeMgr.registerComponentTypes!PhysicsComponent();
    compTypeMgr.registerComponentTypes!TestMultiComponent();
    compTypeMgr.registerComponentTypes!SpawnerMultiComponent();
    compTypeMgr.registerComponentTypes!TimedTriggerMultiComponent();
    compTypeMgr.lock();


    auto scheduler = new Scheduler(4);
    auto entityMgr = new EntityManager!DefaultEntityPolicy(compTypeMgr, scheduler);
    scope(exit) { entityMgr.destroy(); }
    entityMgr.startThreads();
    auto protoMgr = new PrototypeManager(compTypeMgr, entityMgr);

    auto lifeProc        = new TestLifeProcess();
    auto noOutProc       = new TestNoOutputProcess();
    auto physicsProc     = new CopyProcess!PhysicsComponent();
    physicsProc.printComponents = true;
    auto spawnerCopyProc = new CopyProcess!SpawnerMultiComponent();
    auto removeProc      = new TestRemoveComponentProcess();
    auto multiProc       = new TestMultiComponentProcess();
    //XXX implement time management and replace this "1.0 / 60" hack.
    //    A TimeManager class, with 'fixed time manager' and 
    //    'fast time manager' implementations. Passed to EntityManager
    //    in a setter; will also have some kind of default.
    //
    auto timedSpawnConditionProc =
        new TimedTriggerProcess(delegate real(){return 1.0 / 60;});

    auto spawnerProc =
        new SpawnerProcess!DefaultEntityPolicy(&entityMgr.addEntity, protoMgr, compTypeMgr);
    entityMgr.registerProcess(lifeProc);
    entityMgr.registerProcess(noOutProc);
    entityMgr.registerProcess(physicsProc);
    entityMgr.registerProcess(removeProc);
    entityMgr.registerProcess(multiProc);
    entityMgr.registerProcess(spawnerProc);
    entityMgr.registerProcess(spawnerCopyProc);
    entityMgr.registerProcess(timedSpawnConditionProc);
    entityMgr.registerResourceManager(protoMgr);


    int[][8] entityNumbers = [[1],
                              [],
                              [2, 3],
                              [1, 2, 3],
                              [],
                              [1],
                              [3, 3, 4],
                              [4, 5, 1]];
    ResourceHandle!EntityPrototypeResource[][8] entityHandles;
    EntityID[][8] entityIDs;
    foreach(frame; 0 .. 8) foreach(number; entityNumbers[frame])
    {
        auto descriptor = EntityPrototypeResource.
                          Descriptor("test_data/entity%s.yaml".format(number));
        writeln(descriptor.fileName);
        entityHandles[frame] ~= protoMgr.handle(descriptor);
        entityIDs[frame] ~= EntityID.init;

        protoMgr.requestLoad(entityHandles[frame].back);
    }


    foreach(frame; 0 .. 8)
    {
        writeln(q{
        --------
        FRAME %s
        --------
        }.format(frame));

        entityMgr.executeFrame();
        ResourceHandle!EntityPrototypeResource[] handles = entityHandles[frame][];
        EntityID[] ids = entityIDs[frame][];
        foreach(i, ref handle; handles)
        {
            if(protoMgr.state(handle) == ResourceState.Loaded && ids[i].isNull)
            {
                /*writefln("Going to add entity %s %s", frame, handle);*/
                immutable(EntityPrototype)* prototype = &(protoMgr.resource(handle).prototype);
                ids[i] = entityMgr.addEntity(*prototype);
            }
        }
    }
}

unittest
{
    try
    {
        realMain();
    }
    catch(Error e)
    {
        writeln("ERROR");
        writeln(e.msg);
        writeln(e);
    }
}
